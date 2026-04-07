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
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"strings"
	"time"
)

// tartBinary holds the resolved path to the tart executable. It defaults to
// "tart" (bare name, resolved via PATH at exec time) but is overwritten by
// run() with the fully resolved path from config or exec.LookPath. Using a
// package-level variable avoids threading the path through every function
// signature. All exported Tart* functions and the unexported helpers use this.
var tartBinary = DefaultTartBinary

// TartVM represents a single VM entry returned by `tart list --format json`.
// We only capture the fields we need for lifecycle management.
type TartVM struct {
	Name   string `json:"Name"`
	State  string `json:"State"`  // e.g., "running", "stopped"
	Source string `json:"Source"` // OCI image the VM was cloned from
}

// runTart executes a tart command, streaming its combined stdout/stderr through
// the logger line by line in real time. This streaming pattern (as opposed to
// collecting output and logging after completion) is critical for two reasons:
//   - Long-running commands like clone (which pulls OCI images) and run (which
//     blocks for the VM's entire lifetime) would produce no output for minutes
//     or hours if buffered.
//   - The runner startup script's stdout inside tart exec is the primary
//     observability channel into what is happening inside the VM.
func runTart(ctx context.Context, logger *slog.Logger, args ...string) error {
	cmd := exec.CommandContext(ctx, tartBinary, args...)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("tart %s: stdout pipe: %w", args[0], err)
	}
	cmd.Stderr = cmd.Stdout // merge stderr into stdout

	start := time.Now()

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("tart %s: start: %w", args[0], err)
	}

	// Stream output line by line through the logger
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		if line != "" {
			logger.Info(line)
		}
	}

	elapsed := time.Since(start).Round(time.Millisecond)
	if err := cmd.Wait(); err != nil {
		logger.Warn("tart command failed", "duration", elapsed, "error", err)
		return fmt.Errorf("tart %s: %w", strings.Join(args, " "), err)
	}
	logger.Debug("tart command completed", "duration", elapsed)
	return nil
}

// TartClone creates a new VM by cloning an existing base image. The base image
// can be a local image name or an OCI reference (e.g., ghcr.io/...). Tart
// pulls remote images automatically on first use.
func TartClone(ctx context.Context, logger *slog.Logger, baseImage, vmName string) error {
	return runTart(ctx, logger.With("op", "clone", "vm", vmName), "clone", baseImage, vmName)
}

// tartRunArgs builds the argument list for `tart run` in headless mode.
// If sharedDir is non-empty, it is mounted into the VM at the "shared"
// mount point using the --dir flag. The format is [name:]path[:options];
// "shared" is used as the name so it appears at
// /Volumes/My Shared Files/shared/ in the guest.
func tartRunArgs(vmName, sharedDir string) []string {
	args := []string{"run", TartRunNoGraphicsFlag}
	if sharedDir != "" {
		args = append(args, fmt.Sprintf("--dir=%s:%s", TartSharedDirName, sharedDir))
	}
	args = append(args, vmName)
	return args
}

// TartRun starts a VM in headless mode and blocks until it shuts down. If
// sharedDir is non-empty, it is mounted into the VM at the "shared" mount
// point, which the runner agent uses to read its JIT configuration.
func TartRun(ctx context.Context, logger *slog.Logger, vmName, sharedDir string) error {
	return runTart(ctx, logger.With("op", "run", "vm", vmName), tartRunArgs(vmName, sharedDir)...)
}

// TartRunHandle holds a reference to a running tart VM process, providing
// the PID for metrics collection and a channel that delivers the exit error.
type TartRunHandle struct {
	// PID is the OS process ID of the tart CLI process. Used by the
	// MetricsCollector to sample CPU and memory usage.
	PID int32

	// Done receives exactly one value when the tart process exits: nil on
	// success, or the error from cmd.Wait on failure. The channel is
	// buffered (capacity 1) so the sender never blocks.
	Done <-chan error
}

// TartRunAsync starts a VM in headless mode and returns immediately with a
// handle containing the process PID and a channel that receives the exit
// error when the VM shuts down. This is used instead of TartRun when the
// caller needs the PID for metrics collection.
func TartRunAsync(ctx context.Context, logger *slog.Logger, vmName, sharedDir string) (*TartRunHandle, error) {
	args := tartRunArgs(vmName, sharedDir)

	runLogger := logger.With("op", "run", "vm", vmName)
	cmd := exec.CommandContext(ctx, tartBinary, args...)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("tart run: stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout

	start := time.Now()

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("tart run: start: %w", err)
	}

	done := make(chan error, 1)
	go func() {
		// Stream output line by line through the logger.
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			if line != "" {
				runLogger.Info(line)
			}
		}

		elapsed := time.Since(start).Round(time.Millisecond)
		if err := cmd.Wait(); err != nil {
			runLogger.Warn("tart command failed", "duration", elapsed, "error", err)
			done <- fmt.Errorf("tart run: %w", err)
		} else {
			runLogger.Debug("tart command completed", "duration", elapsed)
			done <- nil
		}
		// Close the channel after sending the result so receivers can
		// range over it or detect completion via the close signal.
		close(done)
	}()

	return &TartRunHandle{
		PID:  int32(cmd.Process.Pid),
		Done: done,
	}, nil
}

// TartExec runs a command inside a running VM via the tart guest agent.
// The guest agent must be installed in the VM (all cirruslabs images include it).
func TartExec(ctx context.Context, logger *slog.Logger, vmName string, command ...string) error {
	args := append([]string{"exec", vmName}, command...)
	return runTart(ctx, logger.With("op", "exec", "vm", vmName), args...)
}

// TartStop stops a running VM.
func TartStop(ctx context.Context, logger *slog.Logger, vmName string) error {
	return runTart(ctx, logger.With("op", "stop", "vm", vmName), "stop", vmName)
}

// TartDelete deletes a VM.
func TartDelete(ctx context.Context, logger *slog.Logger, vmName string) error {
	return runTart(ctx, logger.With("op", "delete", "vm", vmName), "delete", vmName)
}

// TartList returns all VMs whose names start with the given prefix. This is
// used primarily for orphan detection on startup: any VMs matching the runner
// prefix that exist before the listener starts are leftovers from a crash.
//
// Unlike other tart commands, this captures output into a buffer for JSON
// parsing rather than streaming through the logger. It does not accept a
// logger parameter because it never needs to stream.
func TartList(ctx context.Context, prefix string) ([]TartVM, error) {
	cmd := exec.CommandContext(ctx, tartBinary, "list", "--format", TartListFormatJSON)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("tart list: stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("tart list: start: %w", err)
	}

	out, err := io.ReadAll(stdout)
	if err != nil {
		return nil, fmt.Errorf("tart list: read: %w", err)
	}

	if err := cmd.Wait(); err != nil {
		return nil, fmt.Errorf("tart list: %w", err)
	}

	var vms []TartVM
	if err := json.Unmarshal(out, &vms); err != nil {
		return nil, fmt.Errorf("tart list: unmarshal: %w", err)
	}

	// Filter to only VMs managed by this controller (matching the prefix).
	var filtered []TartVM
	for _, vm := range vms {
		if strings.HasPrefix(vm.Name, prefix) {
			filtered = append(filtered, vm)
		}
	}
	return filtered, nil
}

// tartExecQuiet runs a tart exec command without streaming output through
// the logger. Used for polling (e.g., guest agent readiness checks) where
// repeated failures are expected during VM boot and would clutter the logs.
// The caller checks only the error return to determine success/failure.
func tartExecQuiet(ctx context.Context, vmName string, command ...string) error {
	args := append([]string{"exec", vmName}, command...)
	cmd := exec.CommandContext(ctx, tartBinary, args...)
	return cmd.Run()
}
