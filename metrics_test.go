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
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestMetricsCollector_RegisterUnregisterPID(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	mc.RegisterPID("runner-1", 12345)

	mc.mu.RLock()
	pid, ok := mc.pids["runner-1"]
	mc.mu.RUnlock()

	if !ok {
		t.Fatal("PID not registered")
	}
	if pid != 12345 {
		t.Errorf("PID = %d, want 12345", pid)
	}

	mc.UnregisterPID("runner-1")

	mc.mu.RLock()
	_, ok = mc.pids["runner-1"]
	mc.mu.RUnlock()

	if ok {
		t.Error("PID should have been unregistered")
	}
}

func TestMetricsCollector_RecordJobCompleted(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	mc.RecordJobCompleted(true, 10*time.Second)
	mc.RecordJobCompleted(true, 5*time.Second)
	mc.RecordJobCompleted(false, 3*time.Second)

	snap := mc.Snapshot()
	if snap.Aggregate.JobsCompleted != 3 {
		t.Errorf("jobs_completed = %d, want 3", snap.Aggregate.JobsCompleted)
	}
	if snap.Aggregate.JobsSucceeded != 2 {
		t.Errorf("jobs_succeeded = %d, want 2", snap.Aggregate.JobsSucceeded)
	}
	if snap.Aggregate.JobsFailed != 1 {
		t.Errorf("jobs_failed = %d, want 1", snap.Aggregate.JobsFailed)
	}
	if snap.Aggregate.TotalJobDuration != 18.0 {
		t.Errorf("total_job_duration = %f, want 18.0", snap.Aggregate.TotalJobDuration)
	}
}

func TestMetricsCollector_SnapshotIsDeepCopy(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	mc.RegisterPID("runner-1", int32(os.Getpid()))

	mc.mu.Lock()
	mc.snapshot.Runners["runner-1"] = RunnerMetrics{
		TartPID:    int32(os.Getpid()),
		CPUPercent: 42.0,
		MemoryRSS:  1024,
	}
	mc.mu.Unlock()

	snap := mc.Snapshot()
	snap.Runners["runner-1"] = RunnerMetrics{CPUPercent: 99.0}

	snap2 := mc.Snapshot()
	if snap2.Runners["runner-1"].CPUPercent != 42.0 {
		t.Errorf("snapshot mutation leaked: got %f, want 42.0", snap2.Runners["runner-1"].CPUPercent)
	}
}

func TestMetricsCollector_CollectHostMetrics(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	host := mc.collectHost(context.Background())

	if host.MemoryTotal == 0 {
		t.Error("host memory_total should be non-zero")
	}
	if host.MemoryUsed == 0 {
		t.Error("host memory_used should be non-zero")
	}
	if host.DiskTotal == 0 {
		t.Error("host disk_total should be non-zero")
	}
}

func TestMetricsCollector_CollectRunnerMetrics(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	pid := int32(os.Getpid())
	mc.RegisterPID("test-runner", pid)

	rs.addIdle("test-runner", &runnerInfo{
		startTime: time.Now().Add(-10 * time.Second),
	})

	runners := mc.collectRunners()

	rm, ok := runners["test-runner"]
	if !ok {
		t.Fatal("test-runner not in collected metrics")
	}
	if rm.TartPID != pid {
		t.Errorf("PID = %d, want %d", rm.TartPID, pid)
	}
	if rm.MemoryRSS == 0 {
		t.Error("memory_rss should be non-zero for own process")
	}
	if rm.Uptime < 9.0 {
		t.Errorf("uptime = %f, want >= 9.0", rm.Uptime)
	}
}

func TestMetricsCollector_RunCollectsOnInterval(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go mc.Run(ctx, 100*time.Millisecond)

	time.Sleep(300 * time.Millisecond)

	snap := mc.Snapshot()
	if snap.CollectedAt.IsZero() {
		t.Error("collected_at should be set after Run")
	}
	if snap.Host.MemoryTotal == 0 {
		t.Error("host metrics should be populated after Run")
	}
}

func TestMetricsCollector_PrometheusHandler(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	pid := int32(os.Getpid())
	mc.RegisterPID("test-runner", pid)
	rs.addIdle("test-runner", &runnerInfo{startTime: time.Now()})
	mc.collect(context.Background())

	mc.RecordJobCompleted(true, 5*time.Second)

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	mc.Handler().ServeHTTP(rec, req)

	body := rec.Body.String()

	expectedMetrics := []string{
		"arc_host_cpu_percent",
		"arc_host_memory_used_bytes",
		"arc_host_memory_total_bytes",
		"arc_host_disk_used_bytes",
		"arc_host_running_vms",
		"graftery_cpu_percent",
		"graftery_memory_rss_bytes",
		"graftery_uptime_seconds",
		"arc_jobs_completed_total",
		"arc_jobs_succeeded_total",
		"arc_jobs_failed_total",
		"arc_jobs_duration_seconds_total",
	}

	for _, metric := range expectedMetrics {
		if !strings.Contains(body, metric) {
			t.Errorf("prometheus output missing metric %q\n\nFull output:\n%s", metric, body)
		}
	}

	if !strings.Contains(body, `runner="test-runner"`) {
		t.Errorf("prometheus output missing runner label\n\nFull output:\n%s", body)
	}
}

func TestMetricsCollector_UnregisterCleansPrometheus(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	pid := int32(os.Getpid())
	mc.RegisterPID("ephemeral", pid)
	rs.addIdle("ephemeral", &runnerInfo{startTime: time.Now()})
	mc.collect(context.Background())

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	mc.Handler().ServeHTTP(rec, req)
	if !strings.Contains(rec.Body.String(), `runner="ephemeral"`) {
		t.Fatal("runner should appear before unregister")
	}

	mc.UnregisterPID("ephemeral")
	rs.remove("ephemeral")
	mc.collect(context.Background())

	rec2 := httptest.NewRecorder()
	mc.Handler().ServeHTTP(rec2, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	if strings.Contains(rec2.Body.String(), `runner="ephemeral"`) {
		t.Error("runner should be removed from prometheus output after unregister")
	}
}

func TestMetricsCollector_HostCPUCount(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	host := mc.collectHost(context.Background())

	if host.CPUCount < 1 {
		t.Errorf("host cpu_count = %d, want >= 1", host.CPUCount)
	}
}

func TestMetricsCollector_PersistentTartProcs(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	pid := int32(os.Getpid())
	mc.RegisterPID("runner-1", pid)

	// After RegisterPID, the tartProcs map should have a persistent handle.
	mc.mu.RLock()
	_, hasTartProc := mc.tartProcs["runner-1"]
	mc.mu.RUnlock()

	if !hasTartProc {
		t.Error("tartProcs should contain a handle after RegisterPID")
	}

	// After UnregisterPID, it should be cleaned up.
	mc.UnregisterPID("runner-1")

	mc.mu.RLock()
	_, hasTartProc = mc.tartProcs["runner-1"]
	mc.mu.RUnlock()

	if hasTartProc {
		t.Error("tartProcs should be empty after UnregisterPID")
	}
}

func TestMetricsCollector_XPCCacheLifecycle(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	// updateXPCProcessCache should not panic with no runners.
	mc.updateXPCProcessCache()

	mc.mu.RLock()
	count := len(mc.xpcProcs)
	mc.mu.RUnlock()

	// We can't guarantee an XPC VM process is running during tests,
	// but the cache should be initialized and not nil.
	if mc.xpcProcs == nil {
		t.Error("xpcProcs map should be initialized")
	}
	_ = count // may be 0 in CI
}

func TestMetricsCollector_CollectRunnersWithUptime(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	pid := int32(os.Getpid())
	mc.RegisterPID("busy-runner", pid)

	// Add runner as busy with a job context to test job duration.
	rs.addIdle("busy-runner", &runnerInfo{
		startTime: time.Now().Add(-30 * time.Second),
		job: &jobContext{
			JobDisplayName: "Test Job",
			Repo:           "test/repo",
		},
	})
	rs.markBusy("busy-runner")

	runners := mc.collectRunners()
	rm, ok := runners["busy-runner"]
	if !ok {
		t.Fatal("busy-runner not in collected metrics")
	}
	if rm.Uptime < 29.0 {
		t.Errorf("uptime = %f, want >= 29.0", rm.Uptime)
	}
	if rm.JobDuration < 29.0 {
		t.Errorf("job_duration = %f, want >= 29.0 (busy with job)", rm.JobDuration)
	}
}

func TestMetricsCollector_SnapshotIncludesAggregate(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	// Record multiple jobs and verify snapshot reflects them.
	mc.RecordJobCompleted(true, 10*time.Second)
	mc.RecordJobCompleted(false, 5*time.Second)

	snap := mc.Snapshot()
	if snap.Aggregate.JobsCompleted != 2 {
		t.Errorf("jobs_completed = %d, want 2", snap.Aggregate.JobsCompleted)
	}
	if snap.Aggregate.JobsSucceeded != 1 {
		t.Errorf("jobs_succeeded = %d, want 1", snap.Aggregate.JobsSucceeded)
	}
	if snap.Aggregate.JobsFailed != 1 {
		t.Errorf("jobs_failed = %d, want 1", snap.Aggregate.JobsFailed)
	}
}

func TestMetricsCollector_RunningVMCount(t *testing.T) {
	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())

	pid := int32(os.Getpid())
	mc.RegisterPID("runner-1", pid)
	mc.RegisterPID("runner-2", pid)
	mc.collect(context.Background())

	snap := mc.Snapshot()
	if snap.Host.RunningVMs != 2 {
		t.Errorf("running_vms = %d, want 2", snap.Host.RunningVMs)
	}

	mc.UnregisterPID("runner-1")
	mc.collect(context.Background())

	snap = mc.Snapshot()
	if snap.Host.RunningVMs != 1 {
		t.Errorf("running_vms = %d, want 1 after unregister", snap.Host.RunningVMs)
	}
}

func TestControlServer_MetricsEndpoint(t *testing.T) {
	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	rs := newRunnerState()
	mc := NewMetricsCollector(&rs, testLogger())
	mc.collect(context.Background())
	mc.RecordJobCompleted(true, 10*time.Second)

	status := NewAppStatus()
	status.SetState(StateRunning)

	go StartControlServer(ctx, socketPath, status, mc, devNullLogger())
	time.Sleep(500 * time.Millisecond)

	resp, err := httpGetUnix(socketPath, "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Errorf("GET /metrics status = %d, want 200", resp.StatusCode)
	}

	body, _ := io.ReadAll(resp.Body)
	bodyStr := string(body)

	if !strings.Contains(bodyStr, "arc_host_memory_total_bytes") {
		t.Error("/metrics missing arc_host_memory_total_bytes")
	}
	if !strings.Contains(bodyStr, "arc_jobs_completed_total") {
		t.Error("/metrics missing arc_jobs_completed_total")
	}
}

func TestControlServer_StatusWithMetrics(t *testing.T) {
	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	rs := newRunnerState()
	rs.addIdle("runner-a", &runnerInfo{startTime: time.Now()})

	mc := NewMetricsCollector(&rs, testLogger())
	mc.RegisterPID("runner-a", int32(os.Getpid()))
	mc.collect(context.Background())
	mc.RecordJobCompleted(true, 5*time.Second)

	status := NewAppStatus()
	status.SetState(StateRunning)
	status.SetRunners(1, 0)
	status.SetRunnerDetails([]RunnerStatus{
		{Name: "runner-a", State: "idle"},
	})

	go StartControlServer(ctx, socketPath, status, mc, devNullLogger())
	time.Sleep(500 * time.Millisecond)

	snap := getStatus(t, socketPath)

	if snap.Host == nil {
		t.Fatal("/status missing host metrics")
	}
	if snap.Host.MemoryTotal == 0 {
		t.Error("host memory_total should be non-zero")
	}

	if snap.Aggregate == nil {
		t.Fatal("/status missing aggregate metrics")
	}
	if snap.Aggregate.JobsCompleted != 1 {
		t.Errorf("aggregate jobs_completed = %d, want 1", snap.Aggregate.JobsCompleted)
	}

	if len(snap.Runners) != 1 {
		t.Fatalf("runners count = %d, want 1", len(snap.Runners))
	}
	if snap.Runners[0].MemoryRSS == 0 {
		t.Error("runner memory_rss should be non-zero (monitoring own process)")
	}
}

func TestDryRun_MetricsInStatus(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping slow dry-run metrics test in short mode")
	}

	socketPath := testSocketPath(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := &Config{
		Name:          "test-metrics",
		ControlSocket: socketPath,
		LogLevel:      "error",
	}

	done := make(chan error, 1)
	go func() {
		done <- runDryRunWithInterval(ctx, cfg, NewAppStatus(), 5*time.Second)
	}()

	waitForState(t, socketPath, "running", 5*time.Second)

	// Host metrics should be populated immediately.
	snap := getStatus(t, socketPath)
	if snap.Host == nil {
		t.Fatal("dry-run /status missing host metrics")
	}
	if snap.Host.MemoryTotal == 0 {
		t.Error("dry-run host memory_total should be non-zero")
	}

	// Wait for a job cycle to complete so aggregate counters are populated.
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		snap = getStatus(t, socketPath)
		if snap.Aggregate != nil && snap.Aggregate.JobsCompleted > 0 {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if snap.Aggregate == nil || snap.Aggregate.JobsCompleted == 0 {
		t.Error("dry-run aggregate jobs_completed should be > 0 after job cycle")
	}

	cancel()
	<-done
}
