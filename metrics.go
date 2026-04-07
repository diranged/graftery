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
	"log/slog"
	"net/http"
	"runtime"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"
)

// RunnerMetrics holds sampled resource usage for a single runner VM process.
// Used in the JSON /status response for the Swift UI.
type RunnerMetrics struct {
	// TartPID is the OS process ID of the tart CLI process managing this runner VM.
	TartPID int32 `json:"tart_pid"`

	// CPUPercent is the combined CPU usage percentage of the tart CLI process
	// plus the runner's proportional share of XPC VM hypervisor processes.
	CPUPercent float64 `json:"cpu_percent"`

	// MemoryRSS is the combined resident set size (in bytes) of the tart CLI
	// process plus the runner's proportional share of XPC VM hypervisor memory.
	MemoryRSS uint64 `json:"memory_rss"`

	// Uptime is the number of seconds since the runner VM was started.
	Uptime float64 `json:"uptime_seconds"`

	// JobDuration is the number of seconds the runner has been executing its
	// current job, or zero if the runner is idle.
	JobDuration float64 `json:"job_duration_seconds"`
}

// HostMetrics holds host-level resource usage.
type HostMetrics struct {
	// CPUPercent is the overall CPU usage percentage across all cores.
	CPUPercent float64 `json:"cpu_percent"`

	// CPUCount is the number of logical CPUs available on the host.
	CPUCount int `json:"cpu_count"`

	// MemoryUsed is the amount of physical memory currently in use (bytes).
	MemoryUsed uint64 `json:"memory_used"`

	// MemoryTotal is the total amount of physical memory on the host (bytes).
	MemoryTotal uint64 `json:"memory_total"`

	// MemoryPercent is the percentage of physical memory currently in use.
	MemoryPercent float64 `json:"memory_percent"`

	// DiskUsed is the amount of disk space used on the root filesystem (bytes).
	DiskUsed uint64 `json:"disk_used"`

	// DiskTotal is the total disk capacity of the root filesystem (bytes).
	DiskTotal uint64 `json:"disk_total"`

	// DiskPercent is the percentage of disk space used on the root filesystem.
	DiskPercent float64 `json:"disk_percent"`

	// RunningVMs is the number of tart VM processes currently being tracked.
	RunningVMs int `json:"running_vms"`
}

// AggregateMetrics holds lifetime counters accumulated over the process lifetime.
type AggregateMetrics struct {
	// JobsCompleted is the total number of jobs that have finished (succeeded + failed).
	JobsCompleted int64 `json:"jobs_completed"`

	// JobsSucceeded is the number of jobs that completed with a "Succeeded" result.
	JobsSucceeded int64 `json:"jobs_succeeded"`

	// JobsFailed is the number of jobs that completed with a non-success result.
	JobsFailed int64 `json:"jobs_failed"`

	// TotalJobDuration is the cumulative wall-clock duration (in seconds) of all
	// completed jobs.
	TotalJobDuration float64 `json:"total_job_duration_seconds"`
}

// MetricsSnapshot is the combined view of all metrics at a point in time.
// Used by the /status JSON endpoint.
type MetricsSnapshot struct {
	// Host contains system-wide CPU, memory, and disk usage.
	Host HostMetrics `json:"host"`

	// Runners maps runner name to its per-process resource usage metrics.
	Runners map[string]RunnerMetrics `json:"runners"`

	// Aggregate contains lifetime job counters accumulated since process start.
	Aggregate AggregateMetrics `json:"aggregate"`

	// CollectedAt is the timestamp when this snapshot was last updated.
	CollectedAt time.Time `json:"collected_at"`
}

// MetricsCollector periodically samples process and host metrics. It exposes
// data in two ways:
//   - Prometheus metrics via a custom registry (served at /metrics)
//   - JSON snapshot merged into the /status response for the Swift UI
type MetricsCollector struct {
	// mu protects all mutable state: pids, tartProcs, xpcProcs, snapshot,
	// and aggregate.
	mu sync.RWMutex

	// runners is a reference to the scaler's runner state, used to read
	// uptime and job duration for each runner.
	runners *runnerState

	// pids maps runner name to the tart CLI process ID. Populated by
	// RegisterPID and cleared by UnregisterPID.
	pids map[string]int32

	// tartProcs holds persistent gopsutil process handles for tart CLI
	// processes, keyed by runner name. Persistent handles are necessary
	// because gopsutil's Percent(0) returns 0 on the first call — it
	// needs the handle from a prior call to compute the CPU time delta.
	tartProcs map[string]*process.Process

	// xpcProcs holds persistent gopsutil process handles for
	// com.apple.Virtualization.VirtualMachine XPC processes, keyed by PID.
	// These are the actual hypervisor processes where VM CPU/memory usage
	// lives. Like tartProcs, persistence is needed for accurate Percent(0).
	xpcProcs map[int32]*process.Process

	// snapshot is the most recent combined metrics view, served via the
	// /status JSON endpoint.
	snapshot MetricsSnapshot

	// aggregate holds lifetime job counters that survive across collection
	// cycles. Updated by RecordJobCompleted.
	aggregate AggregateMetrics

	// logger is the structured logger for metrics collection diagnostics.
	logger *slog.Logger

	// registry is a dedicated Prometheus registry (not the global default)
	// to avoid exposing default process/go collectors that don't add value
	// for this use case.
	registry *prometheus.Registry

	// --- Host gauges ---

	// hostCPU tracks overall host CPU usage percentage.
	hostCPU prometheus.Gauge

	// hostMemoryUsed tracks host memory usage in bytes.
	hostMemoryUsed prometheus.Gauge

	// hostMemoryTotal tracks host total memory in bytes.
	hostMemoryTotal prometheus.Gauge

	// hostMemoryPercent tracks host memory usage as a percentage.
	hostMemoryPercent prometheus.Gauge

	// hostDiskUsed tracks host disk usage in bytes.
	hostDiskUsed prometheus.Gauge

	// hostDiskTotal tracks host total disk capacity in bytes.
	hostDiskTotal prometheus.Gauge

	// hostDiskPercent tracks host disk usage as a percentage.
	hostDiskPercent prometheus.Gauge

	// hostRunningVMs tracks the number of running Tart VM processes.
	hostRunningVMs prometheus.Gauge

	// --- Per-runner gauges (label: runner) ---

	// runnerCPU tracks CPU usage per runner (tart + proportional XPC share).
	runnerCPU *prometheus.GaugeVec

	// runnerMemoryRSS tracks resident set size per runner in bytes.
	runnerMemoryRSS *prometheus.GaugeVec

	// runnerUptime tracks runner uptime in seconds.
	runnerUptime *prometheus.GaugeVec

	// runnerJobDuration tracks current job duration in seconds per runner.
	runnerJobDuration *prometheus.GaugeVec

	// --- Aggregate counters ---

	// jobsCompleted counts total completed jobs (success + failure).
	jobsCompleted prometheus.Counter

	// jobsSucceeded counts jobs that completed successfully.
	jobsSucceeded prometheus.Counter

	// jobsFailed counts jobs that completed with a failure result.
	jobsFailed prometheus.Counter

	// jobsDurationTotal tracks cumulative job duration in seconds.
	jobsDurationTotal prometheus.Counter
}

// NewMetricsCollector creates a new collector with a dedicated Prometheus
// registry. Call Run() to start the background collection goroutine.
func NewMetricsCollector(runners *runnerState, logger *slog.Logger) *MetricsCollector {
	reg := prometheus.NewRegistry()

	mc := &MetricsCollector{
		runners:   runners,
		pids:      make(map[string]int32),
		tartProcs: make(map[string]*process.Process),
		xpcProcs:  make(map[int32]*process.Process),
		logger:    logger,
		registry:  reg,
		snapshot: MetricsSnapshot{
			Runners: make(map[string]RunnerMetrics),
		},

		// Host gauges.
		hostCPU: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_cpu_percent",
			Help: "Host CPU usage percentage.",
		}),
		hostMemoryUsed: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_memory_used_bytes",
			Help: "Host memory used in bytes.",
		}),
		hostMemoryTotal: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_memory_total_bytes",
			Help: "Host total memory in bytes.",
		}),
		hostMemoryPercent: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_memory_percent",
			Help: "Host memory usage percentage.",
		}),
		hostDiskUsed: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_disk_used_bytes",
			Help: "Host disk used in bytes.",
		}),
		hostDiskTotal: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_disk_total_bytes",
			Help: "Host total disk in bytes.",
		}),
		hostDiskPercent: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_disk_percent",
			Help: "Host disk usage percentage.",
		}),
		hostRunningVMs: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "arc_host_running_vms",
			Help: "Number of running Tart VMs.",
		}),

		// Per-runner gauges.
		runnerCPU: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "graftery_cpu_percent",
			Help: "CPU usage of the tart process for a runner.",
		}, []string{"runner"}),
		runnerMemoryRSS: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "graftery_memory_rss_bytes",
			Help: "Resident set size of the tart process for a runner.",
		}, []string{"runner"}),
		runnerUptime: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "graftery_uptime_seconds",
			Help: "Runner uptime in seconds.",
		}, []string{"runner"}),
		runnerJobDuration: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "graftery_job_duration_seconds",
			Help: "Current job duration in seconds.",
		}, []string{"runner"}),

		// Aggregate counters.
		jobsCompleted: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "arc_jobs_completed_total",
			Help: "Total number of jobs completed.",
		}),
		jobsSucceeded: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "arc_jobs_succeeded_total",
			Help: "Total number of jobs that succeeded.",
		}),
		jobsFailed: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "arc_jobs_failed_total",
			Help: "Total number of jobs that failed.",
		}),
		jobsDurationTotal: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "arc_jobs_duration_seconds_total",
			Help: "Total job duration across all jobs in seconds.",
		}),
	}

	// Register all metrics with our custom registry.
	reg.MustRegister(
		mc.hostCPU, mc.hostMemoryUsed, mc.hostMemoryTotal, mc.hostMemoryPercent,
		mc.hostDiskUsed, mc.hostDiskTotal, mc.hostDiskPercent, mc.hostRunningVMs,
		mc.runnerCPU, mc.runnerMemoryRSS, mc.runnerUptime, mc.runnerJobDuration,
		mc.jobsCompleted, mc.jobsSucceeded, mc.jobsFailed, mc.jobsDurationTotal,
	)

	return mc
}

// Handler returns an http.Handler that serves the /metrics endpoint using
// the standard Prometheus text exposition format.
func (mc *MetricsCollector) Handler() http.Handler {
	return promhttp.HandlerFor(mc.registry, promhttp.HandlerOpts{})
}

// RegisterPID associates a runner name with its tart process PID for
// resource monitoring. It also creates a persistent gopsutil process handle
// and primes its CPU measurement so Percent(0) returns real values on the
// next collection cycle. Called when TartRunAsync starts the VM process.
func (mc *MetricsCollector) RegisterPID(name string, pid int32) {
	mc.mu.Lock()
	defer mc.mu.Unlock()
	mc.pids[name] = pid

	// Create a persistent process handle and prime its CPU counter.
	// Percent(0) always returns 0 on the first call because it has no
	// previous measurement to compare against; by calling it here we
	// ensure the next collection cycle gets a real delta.
	if proc, err := process.NewProcess(pid); err == nil {
		proc.Percent(0) //nolint:errcheck // priming call, result is discarded
		mc.tartProcs[name] = proc
	}

	mc.logger.Debug("registered PID for metrics", "runner", name, "pid", pid)
}

// UnregisterPID removes a runner's PID from monitoring and cleans up its
// persistent process handle and Prometheus label series. Called when the
// tart process exits.
func (mc *MetricsCollector) UnregisterPID(name string) {
	mc.mu.Lock()
	defer mc.mu.Unlock()
	delete(mc.pids, name)
	delete(mc.tartProcs, name)
	delete(mc.snapshot.Runners, name)

	// Remove the label series for this runner so stale metrics don't linger.
	mc.runnerCPU.DeleteLabelValues(name)
	mc.runnerMemoryRSS.DeleteLabelValues(name)
	mc.runnerUptime.DeleteLabelValues(name)
	mc.runnerJobDuration.DeleteLabelValues(name)

	mc.logger.Debug("unregistered PID from metrics", "runner", name)
}

// RecordJobCompleted increments the aggregate job counters. It updates both
// the internal aggregate struct (for JSON /status) and the Prometheus
// counters (for /metrics scraping).
func (mc *MetricsCollector) RecordJobCompleted(succeeded bool, duration time.Duration) {
	mc.mu.Lock()
	mc.aggregate.JobsCompleted++
	if succeeded {
		mc.aggregate.JobsSucceeded++
	} else {
		mc.aggregate.JobsFailed++
	}
	mc.aggregate.TotalJobDuration += duration.Seconds()
	mc.mu.Unlock()

	// Update Prometheus counters (thread-safe on their own).
	mc.jobsCompleted.Inc()
	if succeeded {
		mc.jobsSucceeded.Inc()
	} else {
		mc.jobsFailed.Inc()
	}
	mc.jobsDurationTotal.Add(duration.Seconds())
}

// Snapshot returns a thread-safe copy of the latest metrics for the
// JSON /status response.
func (mc *MetricsCollector) Snapshot() MetricsSnapshot {
	mc.mu.RLock()
	defer mc.mu.RUnlock()

	// Deep copy the runners map.
	runners := make(map[string]RunnerMetrics, len(mc.snapshot.Runners))
	for k, v := range mc.snapshot.Runners {
		runners[k] = v
	}

	return MetricsSnapshot{
		Host:        mc.snapshot.Host,
		Runners:     runners,
		Aggregate:   mc.aggregate,
		CollectedAt: mc.snapshot.CollectedAt,
	}
}

// Run starts the background collection loop. It blocks until ctx is cancelled.
func (mc *MetricsCollector) Run(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Collect once immediately at startup.
	mc.collect(ctx)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			mc.collect(ctx)
		}
	}
}

// collect performs one round of metrics sampling and updates both the
// internal snapshot (for JSON) and the Prometheus gauges (for /metrics).
func (mc *MetricsCollector) collect(ctx context.Context) {
	host := mc.collectHost(ctx)
	runners := mc.collectRunners()

	mc.mu.Lock()
	defer mc.mu.Unlock()
	mc.snapshot.Host = host
	mc.snapshot.Host.RunningVMs = len(mc.pids)
	mc.snapshot.Runners = runners
	mc.snapshot.CollectedAt = time.Now()

	// Update Prometheus host gauges.
	mc.hostCPU.Set(host.CPUPercent)
	mc.hostMemoryUsed.Set(float64(host.MemoryUsed))
	mc.hostMemoryTotal.Set(float64(host.MemoryTotal))
	mc.hostMemoryPercent.Set(host.MemoryPercent)
	mc.hostDiskUsed.Set(float64(host.DiskUsed))
	mc.hostDiskTotal.Set(float64(host.DiskTotal))
	mc.hostDiskPercent.Set(host.DiskPercent)
	mc.hostRunningVMs.Set(float64(len(mc.pids)))

	// Update Prometheus per-runner gauges.
	for name, rm := range runners {
		mc.runnerCPU.WithLabelValues(name).Set(rm.CPUPercent)
		mc.runnerMemoryRSS.WithLabelValues(name).Set(float64(rm.MemoryRSS))
		mc.runnerUptime.WithLabelValues(name).Set(rm.Uptime)
		mc.runnerJobDuration.WithLabelValues(name).Set(rm.JobDuration)
	}
}

// collectHost gathers system-wide CPU, memory, and disk metrics.
func (mc *MetricsCollector) collectHost(ctx context.Context) HostMetrics {
	var h HostMetrics
	h.CPUCount = runtime.NumCPU()

	// CPU percent: pass 0 duration to get usage since last call.
	cpuPcts, err := cpu.PercentWithContext(ctx, 0, false)
	if err != nil {
		mc.logger.Debug("failed to collect host CPU", "error", err)
	} else if len(cpuPcts) > 0 {
		h.CPUPercent = cpuPcts[0]
	}

	// Memory.
	vmem, err := mem.VirtualMemoryWithContext(ctx)
	if err != nil {
		mc.logger.Debug("failed to collect host memory", "error", err)
	} else {
		h.MemoryUsed = vmem.Used
		h.MemoryTotal = vmem.Total
		h.MemoryPercent = vmem.UsedPercent
	}

	// Disk (root filesystem).
	usage, err := disk.UsageWithContext(ctx, "/")
	if err != nil {
		mc.logger.Debug("failed to collect host disk", "error", err)
	} else {
		h.DiskUsed = usage.Used
		h.DiskTotal = usage.Total
		h.DiskPercent = usage.UsedPercent
	}

	return h
}

// collectRunners samples per-process metrics for each registered tart PID.
// It also discovers and includes the com.apple.Virtualization.VirtualMachine
// XPC processes where the real VM CPU/memory usage lives. The tart CLI
// process itself is a lightweight wrapper; the XPC process hosts the
// actual hypervisor workload.
func (mc *MetricsCollector) collectRunners() map[string]RunnerMetrics {
	mc.mu.RLock()
	// Copy the pids and tartProcs maps so we don't hold the lock during
	// process queries.
	pids := make(map[string]int32, len(mc.pids))
	for k, v := range mc.pids {
		pids[k] = v
	}
	tartProcs := make(map[string]*process.Process, len(mc.tartProcs))
	for k, v := range mc.tartProcs {
		tartProcs[k] = v
	}
	mc.mu.RUnlock()

	runners := make(map[string]RunnerMetrics, len(pids))

	for name, pid := range pids {
		rm := RunnerMetrics{TartPID: pid}

		// Use the persistent tart process handle if available, falling
		// back to creating a new one (which will return 0 CPU on first call).
		proc, ok := tartProcs[name]
		if !ok {
			var err error
			proc, err = process.NewProcess(pid)
			if err != nil {
				mc.logger.Debug("process not found for metrics", "runner", name, "pid", pid, "error", err)
				continue
			}
		}

		if cpuPct, err := proc.Percent(0); err == nil {
			rm.CPUPercent = cpuPct
		}
		if memInfo, err := proc.MemoryInfo(); err == nil && memInfo != nil {
			rm.MemoryRSS = memInfo.RSS
		}
		mc.logger.Debug("tart process metrics", "runner", name, "pid", pid, "cpu_percent", rm.CPUPercent, "rss_mb", rm.MemoryRSS/1024/1024)

		// Compute uptime and job duration from runner state.
		mc.runners.mu.Lock()
		if info, ok := mc.runners.idle[name]; ok {
			rm.Uptime = time.Since(info.startTime).Seconds()
		} else if info, ok := mc.runners.busy[name]; ok {
			rm.Uptime = time.Since(info.startTime).Seconds()
			if info.job != nil {
				rm.JobDuration = time.Since(info.startTime).Seconds()
			}
		}
		mc.runners.mu.Unlock()

		runners[name] = rm
	}

	// Discover and update persistent XPC VM process handles. Using
	// persistent handles is critical because gopsutil's Percent(0)
	// returns 0 on the first call — it needs two calls to compute
	// a CPU delta. By keeping the process objects alive across
	// collection cycles, subsequent calls return real values.
	mc.updateXPCProcessCache()

	// Collect XPC metrics and distribute across runners.
	xpcCPU, xpcMem := mc.collectXPCMetrics()

	if len(runners) > 0 && (xpcCPU > 0 || xpcMem > 0) {
		mc.mu.RLock()
		xpcCount := len(mc.xpcProcs)
		mc.mu.RUnlock()

		mc.logger.Info("VM metrics collected",
			"xpc_processes", xpcCount,
			"total_xpc_cpu_percent", xpcCPU,
			"total_xpc_memory_mb", xpcMem/1024/1024,
			"runners", len(runners),
		)

		// Distribute XPC VM process metrics across runners. When there is
		// one runner, it gets 100% of all XPC usage. When there are N
		// runners, each gets 1/N (best we can do without XPC correlation).
		share := 1.0 / float64(len(runners))
		for name, rm := range runners {
			rm.CPUPercent += xpcCPU * share
			rm.MemoryRSS += uint64(float64(xpcMem) * share)
			runners[name] = rm
		}
	} else if len(pids) > 0 {
		mc.logger.Debug("no XPC VM processes found", "registered_runners", len(pids))
	}

	return runners
}

// collectXPCMetrics reads CPU and memory from all cached XPC VM process
// handles and returns the totals. This is extracted from collectRunners to
// keep the main collection loop readable.
func (mc *MetricsCollector) collectXPCMetrics() (cpuTotal float64, memTotal uint64) {
	mc.mu.RLock()
	xpcProcs := make(map[int32]*process.Process, len(mc.xpcProcs))
	for k, v := range mc.xpcProcs {
		xpcProcs[k] = v
	}
	mc.mu.RUnlock()

	for xpcPid, xpcProc := range xpcProcs {
		if cpuPct, err := xpcProc.Percent(0); err == nil {
			cpuTotal += cpuPct
			mc.logger.Debug("XPC VM process CPU", "pid", xpcPid, "cpu_percent", cpuPct)
		}
		if memInfo, err := xpcProc.MemoryInfo(); err == nil && memInfo != nil {
			memTotal += memInfo.RSS
			mc.logger.Debug("XPC VM process memory", "pid", xpcPid, "rss_mb", memInfo.RSS/1024/1024)
		}
	}

	return cpuTotal, memTotal
}

// vmXPCProcessName is the name of the macOS XPC service that hosts the
// actual Virtualization.framework VM hypervisor. Each tart VM gets its
// own instance of this process.
const vmXPCProcessName = "com.apple.Virtualization.VirtualMachine"

// updateXPCProcessCache discovers com.apple.Virtualization.VirtualMachine
// XPC processes and maintains persistent process.Process handles for them.
// Persistent handles are required because gopsutil's Percent(0) returns 0
// on the first call — it needs the handle to have been called previously
// to compute the CPU time delta.
func (mc *MetricsCollector) updateXPCProcessCache() {
	allPids, err := process.Pids()
	if err != nil {
		return
	}

	// Build set of currently live XPC VM PIDs.
	liveXPCPids := make(map[int32]bool)
	for _, pid := range allPids {
		proc, err := process.NewProcess(pid)
		if err != nil {
			continue
		}
		name, err := proc.Name()
		if err != nil {
			continue
		}
		if name == vmXPCProcessName {
			liveXPCPids[pid] = true
		}
	}

	mc.mu.Lock()
	defer mc.mu.Unlock()

	// Add newly discovered XPC processes.
	for pid := range liveXPCPids {
		if _, exists := mc.xpcProcs[pid]; !exists {
			proc, err := process.NewProcess(pid)
			if err != nil {
				continue
			}
			// Prime the CPU measurement — first call always returns 0.
			proc.Percent(0) //nolint:errcheck // priming call, result is discarded
			mc.xpcProcs[pid] = proc
			mc.logger.Info("discovered XPC VM process", "pid", pid)
		}
	}

	// Remove stale entries for XPC processes that exited.
	for pid := range mc.xpcProcs {
		if !liveXPCPids[pid] {
			delete(mc.xpcProcs, pid)
			mc.logger.Info("XPC VM process exited", "pid", pid)
		}
	}
}
