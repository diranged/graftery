package main

import (
	"encoding/json"
	"sync"
)

// AppState represents the current lifecycle state of the application.
type AppState int

const (
	StateIdle     AppState = iota
	StateStarting
	StateRunning
	StateStopping
	StateError
)

func (s AppState) String() string {
	switch s {
	case StateIdle:
		return "idle"
	case StateStarting:
		return "starting"
	case StateRunning:
		return "running"
	case StateStopping:
		return "stopping"
	case StateError:
		return "error"
	default:
		return "unknown"
	}
}

// RunnerStatus holds the current state of a single runner VM for the
// control socket API.
type RunnerStatus struct {
	// Name is the unique runner VM name (e.g., "runner-a1b2c3d4").
	Name string `json:"name"`

	// State is the runner lifecycle state: "idle" or "busy".
	State string `json:"state"`

	// Job is the display name of the GitHub Actions job assigned to this
	// runner, if any.
	Job string `json:"job,omitempty"`

	// Repo is the "owner/repo" of the repository that owns the assigned job.
	Repo string `json:"repo,omitempty"`

	// CPUPercent is the combined CPU usage of the tart process and its
	// proportional share of XPC hypervisor processes.
	CPUPercent float64 `json:"cpu_percent,omitempty"`

	// MemoryRSS is the combined resident set size (bytes) of the tart
	// process and its proportional share of XPC hypervisor memory.
	MemoryRSS uint64 `json:"memory_rss,omitempty"`

	// UptimeSecs is the wall-clock time (seconds) since the runner VM was
	// started.
	UptimeSecs float64 `json:"uptime_seconds,omitempty"`

	// JobDurSecs is the wall-clock time (seconds) since the current job
	// started, or zero if the runner is idle.
	JobDurSecs float64 `json:"job_duration_seconds,omitempty"`
}

// StatusSnapshot is the JSON response for the /status control endpoint.
// It provides a complete view of the application state for the Swift UI.
type StatusSnapshot struct {
	// State is the application lifecycle state (idle, starting, running,
	// stopping, or error).
	State string `json:"state"`

	// IdleRunners is the number of runner VMs waiting for a job.
	IdleRunners int `json:"idle_runners"`

	// BusyRunners is the number of runner VMs currently executing a job.
	BusyRunners int `json:"busy_runners"`

	// Runners is the per-runner detail list, including state and metrics.
	Runners []RunnerStatus `json:"runners"`

	// Error holds the most recent fatal error message, if the application
	// is in the error state.
	Error string `json:"error,omitempty"`

	// Host contains system-wide CPU, memory, and disk usage metrics.
	// Nil when no metrics collector is running.
	Host *HostMetrics `json:"host,omitempty"`

	// Aggregate contains lifetime job counters (completed, succeeded,
	// failed, total duration). Nil when no metrics collector is running.
	Aggregate *AggregateMetrics `json:"aggregate,omitempty"`
}

// AppStatus provides thread-safe observable state for the CLI process.
// It is read by the control socket server to generate StatusSnapshot
// responses for the Swift UI.
type AppStatus struct {
	mu          sync.Mutex
	state       AppState
	idleRunners int
	busyRunners int
	runners     []RunnerStatus
	lastError   string
}

func NewAppStatus() *AppStatus {
	return &AppStatus{state: StateIdle}
}

func (s *AppStatus) SetState(state AppState) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = state
	if state != StateError {
		s.lastError = ""
	}
}

func (s *AppStatus) SetError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = StateError
	if err != nil {
		s.lastError = err.Error()
	}
}

func (s *AppStatus) SetRunners(idle, busy int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.idleRunners = idle
	s.busyRunners = busy
}

// SetRunnerDetails updates the per-runner status list. Called by the
// scaler when runner state changes.
func (s *AppStatus) SetRunnerDetails(runners []RunnerStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.runners = runners
}

// Snapshot returns a JSON-serializable copy of the current state.
func (s *AppStatus) Snapshot() StatusSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	runners := s.runners
	if runners == nil {
		runners = []RunnerStatus{}
	}
	return StatusSnapshot{
		State:       s.state.String(),
		IdleRunners: s.idleRunners,
		BusyRunners: s.busyRunners,
		Runners:     runners,
		Error:       s.lastError,
	}
}

// SnapshotJSON returns the snapshot as JSON bytes.
func (s *AppStatus) SnapshotJSON() ([]byte, error) {
	return json.Marshal(s.Snapshot())
}
