package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/diranged/graftery/provisioner"
	"github.com/google/uuid"
)

// run is the core application loop. It validates config, registers a runner
// scale set with GitHub, cleans up orphan VMs from previous runs, then enters
// the listener loop that reacts to job requests by provisioning Tart VMs.
// It blocks until the context is cancelled (SIGINT/SIGTERM) or a fatal error occurs.
func run(ctx context.Context, cfg *Config, status *AppStatus) error {
	if err := cfg.Validate(); err != nil {
		return fmt.Errorf("config: %w", err)
	}

	// Resolve the tart binary path. Explicit --tart-path / tart_path takes
	// precedence; otherwise we search PATH. This must happen early because
	// every subsequent operation (provisioning, cloning, running VMs) depends
	// on being able to invoke tart. The resolved path is written to the
	// package-level tartBinary variable so all tart.go functions use it.
	if cfg.TartPath == "" {
		resolved, err := exec.LookPath(DefaultTartBinary)
		if err != nil {
			return fmt.Errorf("%s\n\n  PATH: %s", ErrTartNotFound, os.Getenv(EnvPath))
		}
		cfg.TartPath = resolved
	}
	tartBinary = cfg.TartPath

	logger := cfg.Logger()
	logger.Info("tart found", "path", cfg.TartPath)
	logger.Info("starting "+AppName,
		"url", cfg.RegistrationURL,
		"name", cfg.Name,
		"base-image", cfg.BaseImage,
		"max-runners", cfg.MaxRunners,
		"min-runners", cfg.MinRunners,
	)

	status.SetState(StateStarting)

	// Ensure a prepared VM image exists. The provisioner clones the upstream
	// base image, boots it, runs bake scripts to install tools and hooks, then
	// saves the result locally. Subsequent runner VMs clone from this prepared
	// image, not the upstream base. The TartAdapter bridges the provisioner
	// package into the main package's tart functions (see tart_adapter.go).
	scriptsDir := cfg.Provisioning.ScriptsDir
	if scriptsDir == "" {
		scriptsDir = filepath.Join(DefaultConfigDir(), DefaultScriptsDirName)
	}
	prov := provisioner.New(
		logger.WithGroup("provisioner"),
		provisioner.Config{
			BaseImage:          cfg.BaseImage,
			PreparedImageName:  cfg.Provisioning.PreparedImageName,
			ScriptsDir:         scriptsDir,
			SkipBuiltinScripts: cfg.Provisioning.SkipBuiltinScripts,
			Reprovision:        cfg.Reprovision,
		},
		&TartAdapter{},
	)
	cloneImage, err := prov.EnsurePreparedImage(ctx)
	if err != nil {
		status.SetError(err)
		return fmt.Errorf("image provisioning: %w", err)
	}
	logger.Info("using prepared image", "image", cloneImage)

	// Create scaleset client.
	scalesetClient, err := cfg.ScalesetClient()
	if err != nil {
		status.SetError(err)
		return fmt.Errorf("creating scaleset client: %w", err)
	}

	// Resolve runner group name to its numeric ID. The "default" group is
	// always ID 1; custom groups require an API lookup.
	var runnerGroupID int
	switch cfg.RunnerGroup {
	case scaleset.DefaultRunnerGroup:
		runnerGroupID = 1
	default:
		runnerGroup, err := scalesetClient.GetRunnerGroupByName(ctx, cfg.RunnerGroup)
		if err != nil {
			status.SetError(err)
			return fmt.Errorf("looking up runner group %q: %w", cfg.RunnerGroup, err)
		}
		runnerGroupID = runnerGroup.ID
	}

	// Register (or re-use) the runner scale set with GitHub. Scale sets are
	// named resources; if the process crashed previously, the scale set may
	// still exist. The create-then-get-then-update fallback handles this:
	//   1. Try to create the scale set.
	//   2. If creation fails (name conflict), look up the existing one.
	//   3. Update the existing scale set with our desired config so labels,
	//      runner group, etc. stay in sync with the current config.
	desiredScaleSet := &scaleset.RunnerScaleSet{
		Name:          cfg.Name,
		RunnerGroupID: runnerGroupID,
		Labels:        cfg.BuildLabels(),
		RunnerSetting: scaleset.RunnerSetting{
			DisableUpdate: true,
		},
	}
	scaleSet, err := scalesetClient.CreateRunnerScaleSet(ctx, desiredScaleSet)
	if err != nil {
		// Scale set already exists from a previous run — reuse it.
		logger.Debug("scale set already exists, will reuse", "error", err)
		existing, getErr := scalesetClient.GetRunnerScaleSet(ctx, runnerGroupID, cfg.Name)
		if getErr != nil {
			status.SetError(err)
			return fmt.Errorf("creating scale set: %w (and lookup failed: %w)", err, getErr)
		}
		// Update the existing scale set with our desired config.
		scaleSet, err = scalesetClient.UpdateRunnerScaleSet(ctx, existing.ID, desiredScaleSet)
		if err != nil {
			status.SetError(err)
			return fmt.Errorf("updating existing scale set %d: %w", existing.ID, err)
		}
		logger.Info("reusing existing scale set", "id", scaleSet.ID, "name", scaleSet.Name)
	} else {
		logger.Info("scale set created", "id", scaleSet.ID, "name", scaleSet.Name)
	}

	// Update system info with the scale set ID.
	scalesetClient.SetSystemInfo(systemInfo(scaleSet.ID))

	// Clean up the scale set registration on exit. Uses WithoutCancel so the
	// cleanup API call still runs even after the context has been cancelled.
	defer func() {
		logger.Info("deleting runner scale set", "id", scaleSet.ID)
		if err := scalesetClient.DeleteRunnerScaleSet(context.WithoutCancel(ctx), scaleSet.ID); err != nil {
			logger.Error("failed to delete runner scale set", "id", scaleSet.ID, "error", err)
		}
	}()

	// Create the Tart scaler.
	scaler := &TartScaler{
		logger:         logger.WithGroup("scaler"),
		runners:        newRunnerState(),
		baseImage:      cloneImage,
		runnerPrefix:   cfg.RunnerPrefix,
		minRunners:     cfg.MinRunners,
		maxRunners:     cfg.MaxRunners,
		scalesetClient: scalesetClient,
		scaleSetID:     scaleSet.ID,
		status:         status,
	}
	defer scaler.Shutdown(context.WithoutCancel(ctx))

	// Create the metrics collector and wire it into the scaler. The collector
	// needs a reference to the scaler's runner state so it can read uptime
	// and job duration from the same data the scaler uses. The scaler in
	// turn uses the collector to register/unregister tart PIDs and record
	// job completion counters. The collector runs in a background goroutine
	// that samples metrics at MetricsCollectionInterval until ctx is cancelled.
	mc := NewMetricsCollector(&scaler.runners, logger.WithGroup("metrics"))
	scaler.metrics = mc
	go mc.Run(ctx, MetricsCollectionInterval)

	// Start the control socket server if configured. Placed after the
	// scaler so the metrics collector can be passed in.
	if cfg.ControlSocket != "" {
		go func() {
			if err := StartControlServer(ctx, cfg.ControlSocket, status, mc, logger); err != nil {
				logger.Error("control socket server failed", "error", err)
			}
		}()
	}

	// Clean up orphan VMs from a previous crash.
	if err := scaler.CleanupOrphans(ctx); err != nil {
		logger.Warn("orphan cleanup failed", "error", err)
	}

	// Create a long-poll message session to receive job requests from GitHub.
	// The hostname is used as the session owner identifier; fall back to a UUID
	// if the hostname is unavailable.
	hostname, err := os.Hostname()
	if err != nil {
		hostname = uuid.NewString()
		logger.Warn("failed to get hostname, using uuid", "hostname", hostname, "error", err)
	}

	// Create a message session. Retry on 409 Conflict (stale session from a
	// previous run that hasn't expired yet — typically clears within 30-60s).
	var sessionClient *scaleset.MessageSessionClient
	for attempt := 1; attempt <= SessionMaxRetries; attempt++ {
		var sessionErr error
		sessionClient, sessionErr = scalesetClient.MessageSessionClient(ctx, scaleSet.ID, hostname)
		if sessionErr == nil {
			break
		}
		if strings.Contains(sessionErr.Error(), SessionConflictStatusCode) && attempt < SessionMaxRetries {
			logger.Info("session conflict, retrying",
				"attempt", attempt,
				"wait", fmt.Sprintf("%ds", attempt*SessionRetryBaseSeconds),
			)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt*SessionRetryBaseSeconds) * time.Second):
			}
			continue
		}
		status.SetError(sessionErr)
		return fmt.Errorf("creating message session: %w", sessionErr)
	}
	defer sessionClient.Close(context.Background())

	// Create and run the listener. The listener polls for messages from GitHub
	// and dispatches scaling events to TartScaler. It blocks until cancelled.
	l, err := listener.New(sessionClient, listener.Config{
		ScaleSetID: scaleSet.ID,
		MaxRunners: cfg.MaxRunners,
		Logger:     logger.WithGroup("listener"),
	})
	if err != nil {
		status.SetError(err)
		return fmt.Errorf("creating listener: %w", err)
	}

	status.SetState(StateRunning)
	logger.Info("listener starting")
	if err := l.Run(ctx, scaler); !errors.Is(err, context.Canceled) {
		status.SetError(err)
		return fmt.Errorf("listener: %w", err)
	}

	status.SetState(StateStopping)
	logger.Info("shutting down")
	return nil
}
