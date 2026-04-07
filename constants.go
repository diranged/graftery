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

import "time"

// ---------------------------------------------------------------------------
// Application identity
// ---------------------------------------------------------------------------

const (
	// AppName is the directory name used for config and data storage.
	AppName = "graftery"

	// AppVersion is the semantic version reported to the GitHub Actions
	// service during scale set registration.
	AppVersion = "0.1.0"

	// AppSubsystem identifies the VM backend in systemInfo metadata.
	AppSubsystem = "tart"
)

// ---------------------------------------------------------------------------
// Configuration file
// ---------------------------------------------------------------------------

const (
	// ConfigFileName is the name of the YAML configuration file.
	ConfigFileName = "config.yaml"

	// ConfigFileHeader is prepended to generated config files so users
	// know what the file is if they open it manually.
	ConfigFileHeader = "# graftery configuration\n# See: https://github.com/diranged/graftery\n\n"
)

// ---------------------------------------------------------------------------
// Default configuration values
// ---------------------------------------------------------------------------

const (
	// DefaultBaseImage is the default Tart VM image used when no
	// --base-image is specified. This is the Cirrus Labs macOS Sonoma
	// runner image from GHCR.
	DefaultBaseImage = "ghcr.io/cirruslabs/macos-runner:sonoma"

	// DefaultMaxRunners is the default maximum number of concurrent VMs.
	DefaultMaxRunners = 2

	// DefaultMinRunners is the default warm pool size.
	DefaultMinRunners = 0

	// DefaultRunnerPrefix is the default VM name prefix used for runner
	// VMs and orphan detection.
	DefaultRunnerPrefix = "runner"

	// DefaultLogLevel is the default log level.
	DefaultLogLevel = "info"

	// DefaultLogFormat is the default log output format.
	DefaultLogFormat = "text"

	// LogFormatJSON is the log format value that selects JSON output.
	LogFormatJSON = "json"

	// DefaultScriptsDirName is the directory name under the config dir
	// where user provisioning scripts are stored.
	DefaultScriptsDirName = "scripts"
)

// ---------------------------------------------------------------------------
// Tart CLI
// ---------------------------------------------------------------------------

const (
	// DefaultTartBinary is the bare binary name used to find tart in PATH.
	DefaultTartBinary = "tart"

	// TartRunNoGraphicsFlag is the flag passed to `tart run` for headless mode.
	TartRunNoGraphicsFlag = "--no-graphics"

	// TartSharedDirName is the mount name used for shared directories
	// between host and guest VM.
	TartSharedDirName = "shared"

	// TartListFormatJSON is the output format flag for `tart list`.
	TartListFormatJSON = "json"

	// VMStateRunning is the tart VM state for running VMs.
	VMStateRunning = "running"

	// ErrTartNotFound is the error message shown when the tart binary
	// cannot be located in PATH and no --tart-path is configured.
	ErrTartNotFound = "tart not found in PATH (set --tart-path or tart_path in config)\n\n" +
		"  Install via Homebrew:  brew install cirruslabs/cli/tart\n" +
		"  More info:            https://tart.run"
)

// ---------------------------------------------------------------------------
// Control socket / HTTP API
// ---------------------------------------------------------------------------

const (
	// ControlPathStatus is the HTTP route for the status endpoint.
	ControlPathStatus = "GET /status"

	// ControlPathHealth is the HTTP route for the health endpoint.
	ControlPathHealth = "GET /health"

	// ControlPathMetrics is the HTTP route for the Prometheus metrics endpoint.
	ControlPathMetrics = "GET /metrics"

	// ContentTypeJSON is the Content-Type header value for JSON responses.
	ContentTypeJSON = "application/json"

	// HealthResponseBody is the body returned by the /health endpoint.
	HealthResponseBody = `{"ok":true}`
)

// ---------------------------------------------------------------------------
// Runner state strings (used in RunnerStatus.State)
// ---------------------------------------------------------------------------

const (
	// RunnerStateIdle is the state string for idle runners.
	RunnerStateIdle = "idle"

	// RunnerStateBusy is the state string for busy runners.
	RunnerStateBusy = "busy"
)

// ---------------------------------------------------------------------------
// Runner VM lifecycle
// ---------------------------------------------------------------------------

const (
	// JITConfigFileName is the filename written to the shared directory
	// containing the base64-encoded JIT runner configuration.
	JITConfigFileName = ".runner_jit_config"

	// RunnerStartupScript is the path to the runner startup script inside
	// the guest VM.
	RunnerStartupScript = "/usr/local/bin/arc-runner-startup.sh"

	// GuestAgentReadyCommand is the command used to probe the tart guest
	// agent for readiness.
	GuestAgentReadyCommand = "echo"

	// GuestAgentReadyArg is the argument passed to the readiness probe.
	GuestAgentReadyArg = "ready"

	// GuestAgentMaxAttempts is the maximum number of readiness probe
	// retries before giving up.
	GuestAgentMaxAttempts = 60

	// GuestAgentPollInterval is the duration between readiness probe
	// retries.
	GuestAgentPollIntervalSeconds = 2

	// GuestAgentLogInterval is the number of attempts between progress
	// log messages during guest agent polling.
	GuestAgentLogInterval = 10
)

// ---------------------------------------------------------------------------
// Network check
// ---------------------------------------------------------------------------

const (
	// NetworkCheckURL is the URL used to verify VM network connectivity.
	NetworkCheckURL = "https://github.com"

	// NetworkCheckMaxTimeSec is the curl --max-time value for the
	// network connectivity check.
	NetworkCheckMaxTimeSec = "10"
)

// ---------------------------------------------------------------------------
// Session / retry
// ---------------------------------------------------------------------------

const (
	// SessionMaxRetries is the maximum number of message session creation
	// attempts (to handle 409 Conflict from stale sessions).
	SessionMaxRetries = 6

	// SessionConflictStatusCode is the HTTP status code string that
	// indicates a stale session conflict.
	SessionConflictStatusCode = "409"

	// SessionRetryBaseSeconds is the base wait time (multiplied by
	// attempt number) between session creation retries.
	SessionRetryBaseSeconds = 10
)

// ---------------------------------------------------------------------------
// Job result
// ---------------------------------------------------------------------------

const (
	// JobResultSucceeded is the result string for a successful job.
	JobResultSucceeded = "Succeeded"

	// VMErrDoesNotExist is the error substring returned by tart when a VM
	// has already been deleted.
	VMErrDoesNotExist = "does not exist"
)

// ---------------------------------------------------------------------------
// Dry-run defaults
// ---------------------------------------------------------------------------

const (
	// DryRunName is the default scale set name used in dry-run mode.
	DryRunName = "dry-run"

	// DryRunURL is the placeholder registration URL used in dry-run mode.
	DryRunURL = "https://github.com/example/dry-run"

	// DryRunImage is the fake prepared image name used in dry-run mode.
	DryRunImage = "dry-run-image"

	// DryRunTempDir is the placeholder temp directory for dry-run runners.
	DryRunTempDir = "/tmp/dry-run"

	// DryRunRepo is the placeholder repository used in dry-run simulations.
	DryRunRepo = "example/dry-run-repo"

	// DryRunEventName is the placeholder event name used in dry-run simulations.
	DryRunEventName = "push"

	// DryRunScaleSetID is the placeholder scale set ID used in dry-run mode.
	DryRunScaleSetID = 999
)

// ---------------------------------------------------------------------------
// Environment variable names
// ---------------------------------------------------------------------------

const (
	// EnvPath is the PATH environment variable name.
	EnvPath = "PATH"
)

// ---------------------------------------------------------------------------
// Metrics collection
// ---------------------------------------------------------------------------

const (
	// MetricsCollectionInterval is the default interval between metrics
	// collection cycles. Each cycle samples host CPU/memory/disk, per-runner
	// tart process stats, and XPC hypervisor process stats. The value is a
	// balance between freshness (for the Swift UI) and CPU overhead from
	// process enumeration. 5 seconds matches common Prometheus scrape intervals.
	MetricsCollectionInterval = 5 * time.Second
)
