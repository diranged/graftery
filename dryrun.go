// Copyright 2026 Matt Wise
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"
)

// runDryRun simulates the full runner lifecycle without connecting to GitHub
// or launching tart VMs. It exercises the same code paths (logging, control
// socket, status updates) so the Swift UI can be tested end-to-end.
//
// The simulation cycles through:
//  1. Fake provisioning (instant)
//  2. Listening for jobs (idle)
//  3. Periodically: receive a fake job → clone → boot → run → complete
//
// The control socket works identically to real mode — the Swift app can't
// tell the difference.
func runDryRun(ctx context.Context, cfg *Config, status *AppStatus) error {
	return runDryRunWithInterval(ctx, cfg, status, 30*time.Second)
}

// runDryRunWithInterval is the implementation of runDryRun with a
// configurable job interval for testing.
func runDryRunWithInterval(ctx context.Context, cfg *Config, status *AppStatus, jobInterval time.Duration) error {
	// Fill in defaults for fields that Validate() would require but
	// dry-run doesn't need.
	if cfg.Name == "" {
		cfg.Name = DryRunName
	}
	if cfg.RegistrationURL == "" {
		cfg.RegistrationURL = DryRunURL
	}
	if cfg.BaseImage == "" {
		cfg.BaseImage = DefaultBaseImage
	}

	logger := cfg.Logger()
	logger.Info("starting "+AppName+" (DRY RUN)",
		"url", cfg.RegistrationURL,
		"name", cfg.Name,
		"base-image", cfg.BaseImage,
		"max-runners", cfg.MaxRunners,
		"min-runners", cfg.MinRunners,
	)

	status.SetState(StateStarting)

	// Simulate provisioning.
	logger.Info("[DRY RUN] provisioning skipped (simulated)")
	logger.Info("using prepared image", "image", DryRunImage)

	// Simulate scale set registration.
	logger.Info("scale set created", "id", DryRunScaleSetID, "name", cfg.Name)

	// Create a mock scaler to track runner state for the control socket.
	scaler := &TartScaler{
		logger:       logger.WithGroup("scaler"),
		runners:      newRunnerState(),
		baseImage:    DryRunImage,
		runnerPrefix: cfg.RunnerPrefix,
		minRunners:   cfg.MinRunners,
		maxRunners:   cfg.MaxRunners,
		status:       status,
	}
	defer scaler.Shutdown(context.WithoutCancel(ctx))

	// Create the metrics collector and wire it into the scaler, identical to
	// the real run() path. In dry-run mode there are no real tart processes,
	// so per-runner CPU/memory will always be zero. However, host-level
	// metrics (CPU, memory, disk) and aggregate job counters (recorded via
	// RecordJobCompleted in simulateJob) still function normally. This lets
	// the Swift UI display realistic host stats during dry-run testing.
	mc := NewMetricsCollector(&scaler.runners, logger.WithGroup("metrics"))
	scaler.metrics = mc
	go mc.Run(ctx, MetricsCollectionInterval)

	// Start the control socket if configured.
	if cfg.ControlSocket != "" {
		go func() {
			if err := StartControlServer(ctx, cfg.ControlSocket, status, mc, logger); err != nil {
				logger.Error("control socket server failed", "error", err)
			}
		}()
	}

	status.SetState(StateRunning)
	logger.Info("listener starting")
	logger.Info("[DRY RUN] simulating job cycle", "interval", jobInterval)

	// Simulate the listener loop: periodically run a fake job.
	ticker := time.NewTicker(jobInterval)
	defer ticker.Stop()

	jobNum := 0
	for {
		select {
		case <-ctx.Done():
			status.SetState(StateStopping)
			logger.Info("shutting down")
			return nil
		case <-ticker.C:
			jobNum++
			simulateJob(ctx, logger, scaler, status, jobNum)
		}
	}
}

// simulateJob simulates a single job lifecycle: scale up, clone, boot,
// run job, complete, clean up. All with realistic timing and log output.
func simulateJob(ctx context.Context, logger *slog.Logger, scaler *TartScaler, status *AppStatus, jobNum int) {
	runnerName := fmt.Sprintf("runner-dry-%04d", jobNum)
	jobName := fmt.Sprintf("Dry Run Job #%d", jobNum)
	repo := DryRunRepo

	logger.Info("scaling up",
		"scaler.current", scaler.runners.count(),
		"scaler.target", scaler.runners.count()+1,
		"scaler.adding", 1,
	)

	// Simulate clone.
	logger.Info("cloning VM", "scaler.name", runnerName, "scaler.base", scaler.baseImage)
	sleep(ctx, 100*time.Millisecond)
	logger.Info("VM cloned", "scaler.name", runnerName, "scaler.clone_duration", "100ms")

	// Track the runner.
	scaler.runners.addIdle(runnerName, &runnerInfo{
		tempDir:   DryRunTempDir,
		startTime: time.Now(),
	})
	scaler.updateStatus()

	// Simulate boot.
	logger.Info("starting VM", "scaler.name", runnerName)
	logger.Info("waiting for VM guest agent", "scaler.vm", runnerName)
	sleep(ctx, 2*time.Second)
	logger.Info("guest agent ready", "scaler.vm", runnerName, "scaler.boot_duration", "2s")
	logger.Info("VM network check passed", "scaler.vm", runnerName, "scaler.duration", "50ms")

	// Simulate runner startup.
	logger.Info("starting runner", "scaler.vm", runnerName)
	logger.Info("arc-runner-startup: starting runner", "scaler.vm", runnerName)
	sleep(ctx, 1*time.Second)
	logger.Info("√ Connected to GitHub", "scaler.vm", runnerName)
	logger.Info("Listening for Jobs", "scaler.vm", runnerName)
	sleep(ctx, 500*time.Millisecond)
	logger.Info(fmt.Sprintf("Running job: %s", jobName), "scaler.vm", runnerName)

	// Simulate HandleJobStarted.
	scaler.runners.setJobContext(runnerName, &jobContext{
		JobDisplayName: jobName,
		JobID:          fmt.Sprintf("dry-run-%d", jobNum),
		Repo:           repo,
		WorkflowRunID:  int64(jobNum),
		EventName:      DryRunEventName,
	})
	scaler.runners.markBusy(runnerName)
	scaler.updateStatus()

	logger.Info("job started",
		"scaler.runner", runnerName,
		"scaler.job", jobName,
		"scaler.repo", repo,
		"scaler.event", DryRunEventName,
	)

	// Simulate job running for 5-10 seconds.
	sleep(ctx, 7*time.Second)

	// Simulate job completion.
	logger.Info(fmt.Sprintf("Job %s completed with result: %s", jobName, JobResultSucceeded),
		"scaler.vm", runnerName)

	logger.Info("job completed",
		"scaler.runner", runnerName,
		"scaler.result", JobResultSucceeded,
		"scaler.job", jobName,
		"scaler.repo", repo,
		"scaler.job_duration", "7s",
	)

	// Record job completion in metrics.
	if scaler.metrics != nil {
		scaler.metrics.RecordJobCompleted(true, 7*time.Second)
	}

	// Clean up.
	scaler.runners.remove(runnerName)
	scaler.updateStatus()
	logger.Info("runner cleaned up", "scaler.vm", runnerName, "scaler.lifetime", "10s")
}

// sleep waits for the given duration or until the context is cancelled.
func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
