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
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"testing"
	"time"
)

// testSocketPath returns a short socket path in /tmp and registers cleanup.
// macOS limits Unix socket paths to 104 chars; t.TempDir() paths are too long.
func testSocketPath(t *testing.T) string {
	t.Helper()
	path := fmt.Sprintf("/tmp/arc-test-%d.sock", time.Now().UnixNano()%100000)
	t.Cleanup(func() { os.Remove(path) })
	return path
}

// httpGetUnix performs an HTTP GET via a Unix domain socket.
func httpGetUnix(socketPath, path string) (*http.Response, error) {
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", socketPath)
			},
		},
		Timeout: 5 * time.Second,
	}
	return client.Get("http://localhost" + path)
}

// getStatus polls /status from the control socket and decodes the response.
func getStatus(t *testing.T, socketPath string) StatusSnapshot {
	t.Helper()
	resp, err := httpGetUnix(socketPath, "/status")
	if err != nil {
		t.Fatalf("GET /status failed: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	var snap StatusSnapshot
	if err := json.Unmarshal(body, &snap); err != nil {
		t.Fatalf("decode /status: %v (body: %s)", err, body)
	}
	return snap
}

// waitForState polls /status until the given state is reached or timeout.
func waitForState(t *testing.T, socketPath, wantState string, timeout time.Duration) StatusSnapshot {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := httpGetUnix(socketPath, "/status")
		if err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		var snap StatusSnapshot
		if err := json.Unmarshal(body, &snap); err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		if snap.State == wantState {
			return snap
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for state %q after %s", wantState, timeout)
	return StatusSnapshot{}
}

func TestDryRun_ControlSocket_Health(t *testing.T) {
	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := &Config{
		Name:          "test-health",
		ControlSocket: socketPath,
		LogLevel:      "error", // quiet output during tests
	}

	// Run dry-run in background.
	done := make(chan error, 1)
	go func() {
		done <- runDryRun(ctx, cfg, NewAppStatus())
	}()

	// Wait for the socket to become available.
	time.Sleep(1 * time.Second)

	resp, err := httpGetUnix(socketPath, "/health")
	if err != nil {
		t.Fatalf("GET /health failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Errorf("GET /health status = %d, want 200", resp.StatusCode)
	}

	body, _ := io.ReadAll(resp.Body)
	if string(body) != `{"ok":true}` {
		t.Errorf("GET /health body = %q, want %q", body, `{"ok":true}`)
	}

	cancel()
	<-done
}

func TestDryRun_ControlSocket_StatusTransitions(t *testing.T) {
	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := &Config{
		Name:          "test-transitions",
		ControlSocket: socketPath,
		LogLevel:      "error",
	}

	done := make(chan error, 1)
	go func() {
		done <- runDryRun(ctx, cfg, NewAppStatus())
	}()

	// Should reach "running" state within a few seconds.
	snap := waitForState(t, socketPath, "running", 5*time.Second)
	if snap.State != "running" {
		t.Errorf("state = %q, want %q", snap.State, "running")
	}
	if snap.IdleRunners != 0 {
		t.Errorf("idle_runners = %d, want 0", snap.IdleRunners)
	}
	if snap.BusyRunners != 0 {
		t.Errorf("busy_runners = %d, want 0", snap.BusyRunners)
	}

	// Cancel and verify clean shutdown.
	cancel()
	<-done
}

func TestDryRun_JobLifecycle(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping slow dry-run job test in short mode")
	}

	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Use a shorter job interval for testing.
	cfg := &Config{
		Name:          "test-job",
		ControlSocket: socketPath,
		LogLevel:      "error",
	}

	status := NewAppStatus()
	done := make(chan error, 1)
	go func() {
		done <- runDryRunWithInterval(ctx, cfg, status, 5*time.Second)
	}()

	// Wait for running state.
	waitForState(t, socketPath, "running", 5*time.Second)

	// Wait for a job to appear (busy runner).
	deadline := time.Now().Add(15 * time.Second)
	sawBusy := false
	for time.Now().Before(deadline) {
		snap := getStatus(t, socketPath)
		if snap.BusyRunners > 0 {
			sawBusy = true
			// Verify runner details.
			if len(snap.Runners) == 0 {
				t.Error("busy_runners > 0 but runners list is empty")
			} else {
				r := snap.Runners[0]
				if r.State != "busy" {
					t.Errorf("runner state = %q, want %q", r.State, "busy")
				}
				if r.Job == "" {
					t.Error("busy runner has empty job name")
				}
				if r.Repo == "" {
					t.Error("busy runner has empty repo")
				}
			}
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !sawBusy {
		t.Error("never saw a busy runner during dry-run job simulation")
	}

	// Wait for the job to complete (back to 0 busy).
	deadline = time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		snap := getStatus(t, socketPath)
		if sawBusy && snap.BusyRunners == 0 {
			// Job completed successfully.
			cancel()
			<-done
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Error("job never completed during dry-run simulation")
	cancel()
	<-done
}

func TestControlServer_StatusEndpoint(t *testing.T) {
	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	status := NewAppStatus()
	status.SetState(StateRunning)
	status.SetRunners(2, 1)
	status.SetRunnerDetails([]RunnerStatus{
		{Name: "runner-a", State: "idle"},
		{Name: "runner-b", State: "busy", Job: "Build", Repo: "org/repo"},
	})

	// Start control server directly (not via dry-run).
	go StartControlServer(ctx, socketPath, status, nil, devNullLogger())

	time.Sleep(500 * time.Millisecond)

	snap := getStatus(t, socketPath)
	if snap.State != "running" {
		t.Errorf("state = %q, want %q", snap.State, "running")
	}
	if snap.IdleRunners != 2 {
		t.Errorf("idle_runners = %d, want 2", snap.IdleRunners)
	}
	if snap.BusyRunners != 1 {
		t.Errorf("busy_runners = %d, want 1", snap.BusyRunners)
	}
	if len(snap.Runners) != 2 {
		t.Fatalf("runners count = %d, want 2", len(snap.Runners))
	}
	if snap.Runners[1].Job != "Build" {
		t.Errorf("runner[1].job = %q, want %q", snap.Runners[1].Job, "Build")
	}
	if snap.Runners[1].Repo != "org/repo" {
		t.Errorf("runner[1].repo = %q, want %q", snap.Runners[1].Repo, "org/repo")
	}

	cancel()
}

func TestAppStatus_Snapshot(t *testing.T) {
	s := NewAppStatus()
	s.SetState(StateRunning)
	s.SetRunners(1, 2)
	s.SetRunnerDetails([]RunnerStatus{
		{Name: "r1", State: "idle"},
	})

	snap := s.Snapshot()
	if snap.State != "running" {
		t.Errorf("state = %q, want %q", snap.State, "running")
	}
	if snap.IdleRunners != 1 || snap.BusyRunners != 2 {
		t.Errorf("runners = %d/%d, want 1/2", snap.IdleRunners, snap.BusyRunners)
	}

	// Test error state.
	s.SetError(os.ErrNotExist)
	snap = s.Snapshot()
	if snap.State != "error" {
		t.Errorf("state = %q, want %q", snap.State, "error")
	}
	if snap.Error == "" {
		t.Error("error field should be set")
	}
}

// devNullLogger returns a logger that discards all output.
func devNullLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
