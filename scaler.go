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
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

// Compile-time check that TartScaler implements listener.Scaler.
var _ listener.Scaler = (*TartScaler)(nil)

// TartScaler implements the listener.Scaler interface using Tart VMs. Each
// runner is an ephemeral VM clone of the base image. The scaler tracks runners
// in two pools (idle and busy) and handles the full lifecycle: clone, run,
// and cleanup. It communicates runner count changes to AppStatus for the UI.
type TartScaler struct {
	logger         *slog.Logger
	runners        runnerState
	baseImage      string
	runnerPrefix   string
	minRunners     int
	maxRunners     int
	scalesetClient *scaleset.Client
	scaleSetID     int
	status *AppStatus

	// metrics is the optional MetricsCollector for recording per-runner
	// resource usage and aggregate job counters. It may be nil during tests
	// or early startup; all call sites guard with a nil check.
	metrics *MetricsCollector
}

// jobContext holds metadata about the GitHub Actions job assigned to a runner.
// This context is attached to a runner when HandleJobStarted fires, and used by
// loggerWithJob to enrich all subsequent log lines for that runner with job
// identity (repo, workflow, job name). This makes it possible to correlate VM
// lifecycle events with specific GitHub Actions workflow runs.
type jobContext struct {
	JobDisplayName string
	JobID          string
	Repo           string // "owner/repo"
	WorkflowRunID  int64
	WorkflowRef    string
	EventName      string
	Labels         []string
}

// runnerInfo holds metadata about a tracked runner VM. Each runner has exactly
// one runnerInfo that lives from startRunner through cleanupRunner. The job
// field starts nil (runner is idle, waiting for work) and is populated when
// HandleJobStarted fires.
type runnerInfo struct {
	tempDir   string      // host-side shared directory with JIT config
	startTime time.Time   // when startRunner was called
	job       *jobContext // populated when HandleJobStarted fires
}

// runnerState is a thread-safe tracker for active runner VMs. Runners start
// in the idle pool and move to busy when a job is assigned.
type runnerState struct {
	mu   sync.Mutex
	idle map[string]*runnerInfo // runner name -> info
	busy map[string]*runnerInfo // runner name -> info
}

// newRunnerState initializes an empty runner state with allocated maps.
func newRunnerState() runnerState {
	return runnerState{
		idle: make(map[string]*runnerInfo),
		busy: make(map[string]*runnerInfo),
	}
}

// count returns the total number of tracked runners (idle + busy).
func (rs *runnerState) count() int {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return len(rs.idle) + len(rs.busy)
}

// counts returns the idle and busy runner counts separately.
func (rs *runnerState) counts() (idle, busy int) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return len(rs.idle), len(rs.busy)
}

// addIdle registers a newly created runner in the idle pool.
func (rs *runnerState) addIdle(name string, info *runnerInfo) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	rs.idle[name] = info
}

// markBusy moves a runner from idle to busy when it picks up a job.
// No-op if the runner is not in the idle pool (e.g., already cleaned up).
func (rs *runnerState) markBusy(name string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	info, ok := rs.idle[name]
	if !ok {
		return
	}
	delete(rs.idle, name)
	rs.busy[name] = info
}

// remove deletes a runner from whichever pool it is in and returns its info.
// Returns false if the runner was already removed (race between the VM
// exit goroutine and HandleJobCompleted).
func (rs *runnerState) remove(name string) (*runnerInfo, bool) {
	rs.mu.Lock()
	defer rs.mu.Unlock()

	if info, ok := rs.busy[name]; ok {
		delete(rs.busy, name)
		return info, true
	}
	if info, ok := rs.idle[name]; ok {
		delete(rs.idle, name)
		return info, true
	}
	return nil, false
}

// activeNames returns the names of all tracked runners.
func (rs *runnerState) activeNames() []string {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	names := make([]string, 0, len(rs.idle)+len(rs.busy))
	for name := range rs.idle {
		names = append(names, name)
	}
	for name := range rs.busy {
		names = append(names, name)
	}
	return names
}

// setJobContext stores job metadata on a runner's info. Called from HandleJobStarted.
func (rs *runnerState) setJobContext(name string, jc *jobContext) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if info, ok := rs.idle[name]; ok {
		info.job = jc
	}
	if info, ok := rs.busy[name]; ok {
		info.job = jc
	}
}

// getJobContext returns the job context for a runner, if available.
func (rs *runnerState) getJobContext(name string) *jobContext {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if info, ok := rs.busy[name]; ok && info.job != nil {
		return info.job
	}
	if info, ok := rs.idle[name]; ok && info.job != nil {
		return info.job
	}
	return nil
}

// loggerWithJob returns a logger enriched with job context fields if available.
// This is the primary mechanism for correlating VM-level log messages (boot,
// exec, exit) with the GitHub job they are serving. If no job has been assigned
// yet (runner is still idle), only the VM name is included.
func (s *TartScaler) loggerWithJob(name string) *slog.Logger {
	l := s.logger.With("vm", name)
	jc := s.runners.getJobContext(name)
	if jc != nil {
		l = l.With(
			"job", jc.JobDisplayName,
			"job_id", jc.JobID,
			"repo", jc.Repo,
			"workflow_run_id", jc.WorkflowRunID,
		)
	}
	return l
}

// updateStatus pushes current runner counts and per-runner details to
// AppStatus, which is read by the control socket API.
func (s *TartScaler) updateStatus() {
	if s.status == nil {
		return
	}
	idle, busy := s.runners.counts()
	s.status.SetRunners(idle, busy)

	// Build per-runner detail list for the control socket /status endpoint.
	s.runners.mu.Lock()
	var details []RunnerStatus
	for name, info := range s.runners.idle {
		rs := RunnerStatus{Name: name, State: RunnerStateIdle}
		if info.job != nil {
			rs.Job = info.job.JobDisplayName
			rs.Repo = info.job.Repo
		}
		details = append(details, rs)
	}
	for name, info := range s.runners.busy {
		rs := RunnerStatus{Name: name, State: RunnerStateBusy}
		if info.job != nil {
			rs.Job = info.job.JobDisplayName
			rs.Repo = info.job.Repo
		}
		details = append(details, rs)
	}
	s.runners.mu.Unlock()
	s.status.SetRunnerDetails(details)
}

// CleanupOrphans stops and deletes any VMs matching the runner prefix.
// Called on startup before the listener begins.
func (s *TartScaler) CleanupOrphans(ctx context.Context) error {
	prefix := s.runnerPrefix + "-"
	vms, err := TartList(ctx, prefix) // TartList doesn't need logger (JSON capture)
	if err != nil {
		return fmt.Errorf("listing orphan VMs: %w", err)
	}

	for _, vm := range vms {
		s.logger.Info("cleaning up orphan VM", "name", vm.Name, "state", vm.State)
		if vm.State == VMStateRunning {
			if err := TartStop(ctx, s.logger, vm.Name); err != nil {
				s.logger.Warn("failed to stop orphan VM", "name", vm.Name, "error", err)
			}
		}
		if err := TartDelete(ctx, s.logger, vm.Name); err != nil {
			s.logger.Warn("failed to delete orphan VM", "name", vm.Name, "error", err)
		}
	}

	if len(vms) > 0 {
		s.logger.Info("orphan cleanup complete", "count", len(vms))
	}
	return nil
}

// HandleDesiredRunnerCount is called by the listener when GitHub reports the
// number of pending jobs. It scales up by creating new VMs until we reach
// min(maxRunners, minRunners + desiredCount). It never scales down -- VMs are
// removed only when jobs complete or the VM exits on its own.
func (s *TartScaler) HandleDesiredRunnerCount(ctx context.Context, count int) (int, error) {
	current := s.runners.count()
	target := min(s.maxRunners, s.minRunners+count)

	if target <= current {
		return current, nil
	}

	needed := target - current
	s.logger.Info("scaling up",
		"current", current,
		"target", target,
		"adding", needed,
		"host_cpus", runtime.NumCPU(),
	)

	// Each runner gets a unique name: prefix + 8-char UUID suffix.
	for range needed {
		name := fmt.Sprintf("%s-%s", s.runnerPrefix, uuid.New().String()[:8])
		if err := s.startRunner(ctx, name); err != nil {
			s.logger.Error("failed to start runner", "name", name, "error", err)
		}
	}

	s.updateStatus()
	return s.runners.count(), nil
}

// HandleJobStarted marks a runner as busy when its job begins.
func (s *TartScaler) HandleJobStarted(ctx context.Context, jobInfo *scaleset.JobStarted) error {
	attrs := []any{
		"runner", jobInfo.RunnerName,
		"runner_id", jobInfo.RunnerID,
		"job", jobInfo.JobDisplayName,
		"job_id", jobInfo.JobID,
		"repo", jobInfo.OwnerName + "/" + jobInfo.RepositoryName,
		"workflow_run_id", jobInfo.WorkflowRunID,
		"workflow_ref", jobInfo.JobWorkflowRef,
		"event", jobInfo.EventName,
		"labels", jobInfo.RequestLabels,
	}
	if !jobInfo.QueueTime.IsZero() {
		attrs = append(attrs, "queue_duration", time.Since(jobInfo.QueueTime).Round(time.Second))
	}
	s.logger.Info("job started", attrs...)
	// Store job context so subsequent VM log lines carry job metadata.
	s.runners.setJobContext(jobInfo.RunnerName, &jobContext{
		JobDisplayName: jobInfo.JobDisplayName,
		JobID:          jobInfo.JobID,
		Repo:           jobInfo.OwnerName + "/" + jobInfo.RepositoryName,
		WorkflowRunID:  jobInfo.WorkflowRunID,
		WorkflowRef:    jobInfo.JobWorkflowRef,
		EventName:      jobInfo.EventName,
		Labels:         jobInfo.RequestLabels,
	})
	s.logger.Debug("runner state: idle -> busy", "runner", jobInfo.RunnerName)
	s.runners.markBusy(jobInfo.RunnerName)
	s.updateStatus()
	return nil
}

// HandleJobCompleted cleans up the runner VM after its job finishes.
func (s *TartScaler) HandleJobCompleted(ctx context.Context, jobInfo *scaleset.JobCompleted) error {
	logLevel := slog.LevelInfo
	if jobInfo.Result != JobResultSucceeded {
		logLevel = slog.LevelWarn
	}

	attrs := []any{
		"runner", jobInfo.RunnerName,
		"runner_id", jobInfo.RunnerID,
		"result", jobInfo.Result,
		"job", jobInfo.JobDisplayName,
		"job_id", jobInfo.JobID,
		"repo", jobInfo.OwnerName + "/" + jobInfo.RepositoryName,
		"workflow_run_id", jobInfo.WorkflowRunID,
		"event", jobInfo.EventName,
	}
	if !jobInfo.FinishTime.IsZero() && !jobInfo.RunnerAssignTime.IsZero() {
		attrs = append(attrs, "job_duration", jobInfo.FinishTime.Sub(jobInfo.RunnerAssignTime).Round(time.Second))
	}
	if !jobInfo.FinishTime.IsZero() && !jobInfo.QueueTime.IsZero() {
		attrs = append(attrs, "total_duration", jobInfo.FinishTime.Sub(jobInfo.QueueTime).Round(time.Second))
	}
	s.logger.Log(ctx, logLevel, "job completed", attrs...)

	// Record metrics for the completed job.
	if s.metrics != nil {
		succeeded := jobInfo.Result == JobResultSucceeded
		var jobDuration time.Duration
		if !jobInfo.FinishTime.IsZero() && !jobInfo.RunnerAssignTime.IsZero() {
			jobDuration = jobInfo.FinishTime.Sub(jobInfo.RunnerAssignTime)
		}
		s.metrics.RecordJobCompleted(succeeded, jobDuration)
	}

	s.cleanupRunner(ctx, jobInfo.RunnerName)
	return nil
}

// Shutdown forcefully stops and deletes all tracked runners (both idle and
// busy). Called during graceful shutdown to ensure no orphan VMs are left.
func (s *TartScaler) Shutdown(ctx context.Context) {
	s.logger.Info("shutting down runners")
	s.runners.mu.Lock()
	defer s.runners.mu.Unlock()

	// Stop idle runners first, then busy ones. Errors are logged but not
	// propagated since we are shutting down regardless.
	for name, info := range s.runners.idle {
		s.logger.Info("removing idle runner", "name", name)
		_ = TartStop(ctx, s.logger, name)
		_ = TartDelete(ctx, s.logger, name)
		if info.tempDir != "" {
			os.RemoveAll(info.tempDir)
		}
	}
	clear(s.runners.idle)

	for name, info := range s.runners.busy {
		s.logger.Info("removing busy runner", "name", name)
		_ = TartStop(ctx, s.logger, name)
		_ = TartDelete(ctx, s.logger, name)
		if info.tempDir != "" {
			os.RemoveAll(info.tempDir)
		}
	}
	clear(s.runners.busy)
}

// startRunner provisions a single ephemeral runner VM. It requests a JIT
// (just-in-time) runner configuration from GitHub, writes it to a temp
// directory that will be shared with the VM, clones the base image, and
// launches the VM in a background goroutine.
//
// The background goroutine blocks on TartRun until the VM powers off, then
// calls cleanupRunner. This means cleanup can be triggered from two places:
//   - The VM exits on its own (runner finishes, guest shuts down) -- the
//     goroutine calls cleanupRunner.
//   - HandleJobCompleted fires (GitHub reports the job is done) -- the
//     listener calls cleanupRunner.
//
// Both paths go through runnerState.remove(), which returns false on the second
// call, making the race harmless. Whichever fires first performs the actual
// cleanup; the other is a no-op.
func (s *TartScaler) startRunner(ctx context.Context, name string) error {
	// Generate JIT runner config from GitHub. This config is a one-time-use
	// token that the runner agent inside the VM uses to register itself.
	jit, err := s.scalesetClient.GenerateJitRunnerConfig(
		ctx,
		&scaleset.RunnerScaleSetJitRunnerSetting{Name: name},
		s.scaleSetID,
	)
	if err != nil {
		return fmt.Errorf("generating JIT config: %w", err)
	}

	// Create a temp directory on the host that will be mounted into the VM
	// via Tart's --dir flag. The runner agent reads the JIT config from here.
	tempDir, err := os.MkdirTemp("", name+"-")
	if err != nil {
		return fmt.Errorf("creating temp dir: %w", err)
	}

	// Write JIT config to shared directory for the VM startup script.
	if err := writeJITConfig(tempDir, jit.EncodedJITConfig); err != nil {
		os.RemoveAll(tempDir)
		return fmt.Errorf("writing JIT config: %w", err)
	}

	cloneStart := time.Now()
	s.logger.Info("cloning VM", "name", name, "base", s.baseImage)
	if err := TartClone(ctx, s.logger, s.baseImage, name); err != nil {
		os.RemoveAll(tempDir)
		return fmt.Errorf("cloning VM: %w", err)
	}
	s.logger.Info("VM cloned", "name", name, "clone_duration", time.Since(cloneStart).Round(time.Millisecond))

	s.runners.addIdle(name, &runnerInfo{tempDir: tempDir, startTime: time.Now()})

	// Start the VM asynchronously. TartRunAsync returns immediately with
	// the PID (for metrics) and a channel that fires when the VM exits.
	// We use WithoutCancel so the VM process is not killed if the parent
	// context is cancelled during shutdown — Shutdown() handles that.
	s.logger.Info("starting VM", "name", name)
	handle, err := TartRunAsync(context.WithoutCancel(ctx), s.logger, name, tempDir)
	if err != nil {
		s.runners.remove(name)
		os.RemoveAll(tempDir)
		return fmt.Errorf("starting VM: %w", err)
	}

	// Register the tart process PID for metrics collection.
	if s.metrics != nil {
		s.metrics.RegisterPID(name, handle.PID)
	}

	vmDone := make(chan struct{})
	go func() {
		defer close(vmDone)
		err := <-handle.Done
		if err != nil {
			vmLog := s.loggerWithJob(name)
			vmLog.Error("VM exited with error", "error", err)
		} else {
			vmLog := s.loggerWithJob(name)
			vmLog.Info("VM exited normally")
		}

		// Unregister PID before cleanup.
		if s.metrics != nil {
			s.metrics.UnregisterPID(name)
		}

		// VM has shut down — clean up.
		s.cleanupRunner(context.WithoutCancel(ctx), name)
	}()

	// Once the VM boots, start the runner inside it via tart exec.
	go s.startRunnerInVM(context.WithoutCancel(ctx), name, vmDone)

	return nil
}

// cleanupRunner deletes the VM and removes it from state. It is safe to call
// from multiple goroutines concurrently -- the first call performs the actual
// cleanup and the second is a no-op (see runnerState.remove). This is important
// because both the TartRun goroutine exit and HandleJobCompleted may trigger
// cleanup for the same runner.
func (s *TartScaler) cleanupRunner(ctx context.Context, name string) {
	// Grab job-enriched logger before removing (remove clears the context).
	cleanupLogger := s.loggerWithJob(name)

	info, ok := s.runners.remove(name)
	if !ok {
		cleanupLogger.Debug("runner already cleaned up")
		return
	}

	if err := TartDelete(ctx, s.logger, name); err != nil {
		// "does not exist" is expected — the VM may have been deleted by
		// tart itself after shutdown. Only warn for unexpected errors.
		if strings.Contains(err.Error(), VMErrDoesNotExist) {
			cleanupLogger.Debug("VM already deleted", "error", err)
		} else {
			cleanupLogger.Warn("failed to delete VM", "error", err)
		}
	}

	if info.tempDir != "" {
		os.RemoveAll(info.tempDir)
	}

	lifetime := time.Since(info.startTime).Round(time.Second)
	s.updateStatus()
	cleanupLogger.Info("runner cleaned up", "lifetime", lifetime)
}

// startRunnerInVM waits for the guest agent to come up, then launches the
// runner startup script inside the VM via tart exec. The script reads the
// JIT config from the shared mount, starts the GitHub Actions runner, and
// shuts the VM down when the job completes. All output is streamed through
// the logger in real time.
//
// The vmDone channel is used to bail out early if TartRun exits before the
// guest agent becomes reachable (e.g., the VM image is broken). Without this,
// the readiness loop would spin for the full 60 attempts on a dead VM.
//
// The lifecycle is: poll guest agent -> network check -> run startup script.
// The startup script is expected to self-terminate the VM when done; if it
// fails, the TartRun goroutine will detect the exit and clean up.
func (s *TartScaler) startRunnerInVM(ctx context.Context, name string, vmDone <-chan struct{}) {
	vmLogger := s.logger.With("vm", name)
	bootStart := time.Now()

	// Wait for the guest agent (VM needs to boot first).
	vmLogger.Info("waiting for VM guest agent")
	for i := 0; i < GuestAgentMaxAttempts; i++ {
		select {
		case <-vmDone:
			return // VM already exited
		default:
		}
		if err := tartExecQuiet(ctx, name, GuestAgentReadyCommand, GuestAgentReadyArg); err == nil {
			break
		}
		if i > 0 && i%GuestAgentLogInterval == 0 {
			vmLogger.Info("still waiting for guest agent", "attempt", i, "elapsed", time.Since(bootStart).Round(time.Second))
		}
		select {
		case <-vmDone:
			return
		case <-time.After(GuestAgentPollIntervalSeconds * time.Second):
		}
	}

	bootDuration := time.Since(bootStart).Round(time.Second)
	vmLogger.Info("guest agent ready", "boot_duration", bootDuration)

	// Re-fetch logger with job context — HandleJobStarted may have fired
	// during boot, enriching the runner's metadata with repo/job info.
	vmLogger = s.loggerWithJob(name)

	// Quick network connectivity check before starting the runner.
	netStart := time.Now()
	if err := tartExecQuiet(ctx, name, "curl", "-sf", "--max-time", NetworkCheckMaxTimeSec, "-o", "/dev/null", NetworkCheckURL); err != nil {
		vmLogger.Warn("VM network check failed", "duration", time.Since(netStart).Round(time.Millisecond), "error", err)
	} else {
		vmLogger.Info("VM network check passed", "duration", time.Since(netStart).Round(time.Millisecond))
	}

	vmLogger.Info("starting runner")
	runnerStart := time.Now()
	if err := TartExec(ctx, vmLogger, name, RunnerStartupScript); err != nil {
		vmLogger.Error("runner startup script failed", "error", err, "duration", time.Since(runnerStart).Round(time.Second))
	} else {
		vmLogger.Info("runner startup script exited", "duration", time.Since(runnerStart).Round(time.Second))
	}
}

// writeJITConfig writes the base64-encoded JIT configuration to a well-known
// file in the shared directory. The runner agent inside the VM looks for
// ".runner_jit_config" in its shared mount to auto-register with GitHub.
func writeJITConfig(sharedDir, encodedJITConfig string) error {
	path := filepath.Join(sharedDir, JITConfigFileName)
	return os.WriteFile(path, []byte(encodedJITConfig), 0600)
}
