# Architecture

This document describes the architecture of `graftery` for developers
working on or integrating with the project.

---

## 1. Overview

`graftery` is a GitHub Actions runner autoscaler for macOS. It uses
[Tart](https://tart.run) to manage ephemeral Apple Silicon VMs and the
[actions/scaleset](https://github.com/actions/scaleset) library to communicate
with GitHub's runner scale set API -- the same protocol that Actions Runner
Controller (ARC) uses inside Kubernetes, but running natively on a Mac host.

The tool registers a runner scale set with GitHub, long-polls for job demand,
and dynamically clones/runs/deletes Tart VMs to satisfy that demand. Each VM
receives a JIT (just-in-time) runner configuration, executes exactly one job,
and is destroyed afterward.

---

## 2. System Architecture

The project has a **two-component design**:

| Component | Language | Role |
|-----------|----------|------|
| **Go CLI engine** (`graftery-cli`) | Go | All business logic: GitHub API, scale set listener, Tart VM lifecycle, configuration parsing |
| **Swift macOS app** (`Graftery`) | Swift / SwiftUI | Menu bar UI, subprocess management, configuration editor, setup wizard, log viewer |

The Swift app is a thin wrapper. It does not contain any scaling or GitHub
logic. It launches the Go binary as a child process, passing `--config <path>`
as the sole argument, and consumes its stdout/stderr for log display.

---

## 3. Component Diagram

```
+-----------------------------------------------------------------------+
|                        macOS Host                                     |
|                                                                       |
|  +-----------------------------+    +------------------------------+  |
|  |  Graftery.app (Swift)     |    |  GitHub Actions              |  |
|  |                             |    |                              |  |
|  |  MenuBarExtra               |    |  workflow_job events         |  |
|  |    |-- Start/Stop           |    +-------------|----------------+  |
|  |    |-- Configuration...     |                  |                   |
|  |    |-- View Logs...         |                  v                   |
|  |    +-- Quit                 |    +------------------------------+  |
|  |                             |    |  Scale Set API               |  |
|  |  RunnerManager              |    +-------------|----------------+  |
|  |    |                        |                  |                   |
|  |    | Process.run()          |                  |                   |
|  |    | --config <path>        |                  |                   |
|  |    v                        |                  |                   |
|  +----+------------------------+                  |                   |
|       |                                           |                   |
|       | stdin/stdout/stderr                       |                   |
|       v                                           v                   |
|  +---------------------------------------------------------------+   |
|  |  graftery-cli (Go)                                    |   |
|  |                                                               |   |
|  |  cobra CLI  --->  run()  --->  scaleset.Client                |   |
|  |                     |              |                           |   |
|  |                     v              v                           |   |
|  |              listener.Run()  <--- Scale Set API (long-poll)   |   |
|  |                     |                                         |   |
|  |                     v                                         |   |
|  |              TartScaler (listener.Scaler)                     |   |
|  |                |         |            |                       |   |
|  |                v         v            v                       |   |
|  |           tart clone  tart run    tart delete                 |   |
|  +---------------------------------------------------------------+   |
|                |                                                     |
|                v                                                     |
|  +---------------------------------------------------------------+   |
|  |  Tart VMs                                                     |   |
|  |  runner-a1b2c3d4   runner-e5f6g7h8   ...                     |   |
|  |  (ephemeral, one job each, auto-shutdown)                     |   |
|  +---------------------------------------------------------------+   |
+-----------------------------------------------------------------------+
```

---

## 4. Go CLI Engine

### Entry point: `main.go`

The CLI uses [cobra](https://github.com/spf13/cobra) with a single root
command. It supports two configuration modes:

1. **CLI flags** -- every config field has a corresponding `--flag`.
2. **YAML config file** -- `--config <path>` loads a YAML file first, then any
   explicit flags override file values.

The flag-then-file layering works because `main()` creates a `Config` struct
with defaults, optionally overwrites it from `LoadConfigFile()`, and then cobra
flags override individual fields.

### Core flow: `run.go`

`run()` is the heart of the application:

```
run(ctx, cfg, status)
  |
  |--> cfg.Validate()               # Ensure required fields are set
  |--> cfg.ScalesetClient()          # Create GitHub API client (App or PAT auth)
  |--> CreateRunnerScaleSet()        # Register scale set with GitHub
  |--> TartScaler{...}              # Build the Tart scaler
  |--> scaler.CleanupOrphans()       # Kill leftover VMs from a previous crash
  |--> MessageSessionClient()        # Open long-poll message session
  |--> listener.New() + l.Run()      # Block: dispatch events to TartScaler
  |
  |--> (on ctx cancel) Shutdown()    # Stop + delete all tracked VMs
  |--> DeleteRunnerScaleSet()        # Deregister from GitHub
```

### Key source files

| File | Purpose |
|------|---------|
| `main.go` | Cobra root command, flag definitions, signal handling |
| `run.go` | Orchestrates the full lifecycle: client, scale set, listener |
| `config.go` | `Config` struct with YAML tags, `Validate()`, `ScalesetClient()`, `Logger()`, `BuildLabels()` |
| `configfile.go` | `LoadConfigFile()`, `SaveConfigFile()`, `EnsureConfigFile()`, default paths |
| `scaler.go` | `TartScaler` implementing `listener.Scaler` interface |
| `tart.go` | Thin wrappers around the `tart` CLI: `TartClone`, `TartRun`, `TartStop`, `TartDelete`, `TartList` |
| `status.go` | `AppStatus` -- thread-safe observable state (state, runner counts, errors) |

### Dependencies

| Module | Role |
|--------|------|
| `github.com/actions/scaleset` | Scale set client, listener, protocol types |
| `github.com/spf13/cobra` | CLI flag parsing |
| `github.com/google/uuid` | Unique runner name generation |
| `gopkg.in/yaml.v3` | Config file parsing |

---

## 5. Swift macOS App

### Package layout

The Swift app lives in `ConfigUI/` and is a Swift Package Manager executable
targeting macOS 14+. It depends on [Yams](https://github.com/jpsim/Yams) for
YAML encoding/decoding to stay compatible with the Go config format.

```
ConfigUI/
  Package.swift
  Sources/
    ConfigUIApp.swift      # @main App, MenuBarExtra, window scenes
    RunnerManager.swift    # Subprocess lifecycle, log capture
    Config.swift           # AppConfig (mirrors Go Config struct)
    ConfigEditorView.swift # Tabbed configuration editor
    WizardView.swift       # 5-step setup wizard for first launch
    LogViewerView.swift    # Real-time log viewer (macOS Unified Logging)
```

### App structure: `ConfigUIApp.swift`

`GrafteryApp` is a SwiftUI `App` that declares:

- **`MenuBarExtra`** -- the primary interface. The app sets `LSUIElement=true`
  in Info.plist, so it appears only in the menu bar with no Dock icon. The menu
  provides Start/Stop controls, status display, and window openers.

- **`Window("config")`** -- the tabbed configuration editor
  (`ConfigEditorView`).

- **`Window("logs")`** -- the real-time log viewer (`LogViewerView`).

- **`Window("wizard")`** -- the first-launch setup wizard (`WizardView`).

A `MenuBarLabel` view watches `RunnerManager.needsWizard` and automatically
opens the wizard window on first launch.

### Subprocess management: `RunnerManager.swift`

`RunnerManager` is an `@MainActor ObservableObject` that owns the Go CLI
process:

- **`start()`** -- Locates the CLI binary (inside the app bundle at
  `Contents/Resources/graftery-cli`), launches it as a `Process` with
  `["--config", configPath]`, and pipes stdout+stderr through a `Pipe`.

- **Log capture** -- `pipe.fileHandleForReading.readabilityHandler` reads
  output on a background thread, dispatches lines to the main actor, and
  appends them to `@Published var logLines`. The buffer is capped at 10,000
  lines.

- **State detection** -- While in `.starting` state, log lines are scanned for
  `"listener starting"` or `"scale set ready"` to transition to `.running`.

- **`stop()`** -- Sends `SIGINT` (`proc.interrupt()`) for graceful shutdown.
  The Go binary handles this via `signal.NotifyContext`.

- **`stopAndWait()`** -- Sends SIGINT and blocks until the process exits. Used
  before quit and before restart.

- **Auto-start** -- On init, after a 0.5s delay, `autoStartOrWizard()` checks
  if the config file has required fields (`url`, `name`). If so, it calls
  `start()`. Otherwise, it sets `needsWizard = true` to trigger the wizard.

### Configuration editor: `ConfigEditorView.swift`

A tabbed preferences window with five tabs:

| Tab | Fields |
|-----|--------|
| General | Registration URL, scale set name, labels, runner group, runner prefix |
| Authentication | GitHub App (client ID, installation ID, private key) or PAT |
| Runners | Base image, max runners, min runners |
| Logging | Log level, log format, log destinations (read-only) |
| About | Version, links |

The editor **autosaves** on every change. When the runner is already running,
saving triggers an automatic restart via `runner.restart()`.

### Setup wizard: `WizardView.swift`

A 5-step guided setup for first-time users:

1. GitHub Connection (registration URL)
2. Authentication (GitHub App or PAT)
3. VM Settings (base image, concurrency)
4. Runner Settings (name, labels, group, prefix)
5. Logging (level, format)

Each step validates before allowing the user to proceed. On completion, the
wizard saves the config and calls `onComplete`, which clears `needsWizard` and
calls `runner.start()`.

### Log viewer: `LogViewerView.swift`

Streams logs from macOS Unified Logging by running `/usr/bin/log stream` as a
subprocess filtered to `subsystem == "com.diranged.graftery"`. Features:

- Real-time streaming with pause/resume
- Text search filtering
- Log level filtering (debug/info/warn/error)
- Auto-scroll toggle
- 10,000-line buffer cap

Note: The log viewer reads from macOS Unified Logging (os_log), not directly
from the Go process's stdout. The Go binary is expected to emit structured logs
to stderr which the RunnerManager captures, but the LogViewerView taps into the
system-level log stream for a richer view.

---

## 6. Data Flow

### Configuration flow

```
                          First Launch                    Normal Launch
                          ───────────                    ─────────────
                               |                              |
                               v                              |
                        WizardView (5 steps)                  |
                               |                              |
                               v                              v
                        AppConfig.save()              AppConfig.load()
                               |                              |
                               v                              v
                    ~/Library/Application Support/     (same file)
                    graftery/config.yaml
                               |
                               v
                    RunnerManager.start()
                               |
                               v
                    Process: graftery-cli --config <path>
                               |
                               v
                    Go: LoadConfigFile(path) --> Config struct
                               |
                               v
                    Go: run(ctx, cfg, status)
```

The YAML config file is the single source of truth shared between both
processes. The Swift `AppConfig` struct mirrors the Go `Config` struct field
for field, using matching `CodingKeys` that align with Go's `yaml:"..."` tags.

### Log flow

```
Go CLI (stderr)                 Swift App
────────────                    ─────────
slog.Logger                     RunnerManager
  |                               |
  +--> text/json to stderr ---->  Pipe.readabilityHandler
                                    |
                                    v
                                  logLines (in-memory, @Published)
                                    |
                                    v
                                  (displayed in menu bar state)

macOS Unified Logging             LogViewerView
──────────────────                ─────────────
os_log subsystem:                 /usr/bin/log stream
  com.diranged.graftery     --predicate subsystem == "..."
  |                                   |
  +-- os_log entries  ------------->  pipe --> parseLine() --> logLines
```

---

## 7. Scaler Lifecycle

`TartScaler` implements the `listener.Scaler` interface from `actions/scaleset`.
The listener long-polls GitHub and dispatches three callbacks:

### HandleDesiredRunnerCount(ctx, count) -> (int, error)

Called when GitHub reports how many jobs are pending.

1. Compute `target = min(maxRunners, minRunners + count)`.
2. If `target <= current`, return early.
3. For each runner needed:
   a. Generate a unique name: `<prefix>-<uuid8>` (e.g., `runner-a1b2c3d4`).
   b. Call `scalesetClient.GenerateJitRunnerConfig()` to get a JIT token.
   c. Create a temp directory; write the encoded JIT config to
      `<tempdir>/.runner_jit_config`.
   d. `tart clone <base-image> <name>` -- create a new VM from the base image.
   e. Add runner to idle state map.
   f. Launch `tart run --no-graphics --dir=<tempdir>:shared <name>` in a
      **background goroutine**. This blocks until the VM shuts down.
   g. When `tart run` returns, the goroutine calls `cleanupRunner()`.

### HandleJobStarted(ctx, jobInfo)

Called when a runner picks up a job.

1. Log the runner name and job display name.
2. Move the runner from the `idle` map to the `busy` map.
3. Update status counts.

### HandleJobCompleted(ctx, jobInfo)

Called when a job finishes (success or failure).

1. Log the runner name, job name, and result.
2. Call `cleanupRunner()` which removes the runner from state and runs
   `tart delete`.

### Runner state tracking

`runnerState` is a mutex-protected pair of maps:

```go
type runnerState struct {
    mu   sync.Mutex
    idle map[string]string  // runner name -> temp dir
    busy map[string]string  // runner name -> temp dir
}
```

This enables accurate idle/busy counts for the UI and ensures cleanup is
idempotent (the background goroutine and `HandleJobCompleted` may race; the
first to call `remove()` wins).

### VM lifecycle (per runner)

```
1. tart clone <base-image> runner-<uuid8>
2. Write JIT config to temp dir as .runner_jit_config
3. tart run --no-graphics --dir=<tempdir>:shared runner-<uuid8>
     (background goroutine, blocks until VM exits)
4. Inside the VM:
     - Startup script reads JIT config from /Volumes/shared/.runner_jit_config
     - Starts the Actions runner in JIT/ephemeral mode
     - Runner executes one job then exits
     - VM auto-shuts down (configured in the base image)
5. tart run returns --> cleanupRunner():
     - tart delete runner-<uuid8>
     - Remove temp directory
     - Update status
```

### Crash recovery

On startup, before the listener begins, `CleanupOrphans()`:

1. Calls `tart list --format json` and filters VMs matching the runner prefix.
2. Stops any running orphans (`tart stop`).
3. Deletes all orphans (`tart delete`).

No persistent state file is needed. GitHub automatically retries jobs that were
in progress on orphaned runners.

### Shutdown

On SIGINT/SIGTERM or context cancellation:

1. The listener exits.
2. `TartScaler.Shutdown()` iterates both idle and busy maps, calling
   `tart stop` + `tart delete` for each VM and removing temp directories.
3. `scalesetClient.DeleteRunnerScaleSet()` deregisters from GitHub.
4. The message session is closed.

---

## 8. Configuration

### File location

```
~/Library/Application Support/graftery/config.yaml
```

Both the Go binary (`configfile.go:DefaultConfigPath()`) and the Swift app
(`Config.swift:AppConfig.defaultPath`) agree on this path.

### YAML format

```yaml
# graftery configuration
# See: https://github.com/diranged/graftery

url: https://github.com/my-org
name: my-macos-runner
app_client_id: Iv1.abc123
app_installation_id: 12345678
app_private_key_path: /path/to/private-key.pem
base_image: ghcr.io/cirruslabs/macos-runner:sonoma
max_runners: 2
min_runners: 0
labels:
  - self-hosted
  - macOS
runner_group: default
runner_prefix: runner
log_level: info
log_format: text
```

### Defaults

| Field | Default |
|-------|---------|
| `base_image` | `ghcr.io/cirruslabs/macos-runner:sonoma` |
| `max_runners` | `2` |
| `min_runners` | `0` |
| `runner_prefix` | `runner` |
| `runner_group` | `default` |
| `log_level` | `info` |
| `log_format` | `text` |

Defaults are applied both in `main.go` (for CLI flags) and in
`LoadConfigFile()` (for YAML loading), so they stay consistent.

### Authentication modes

Either GitHub App credentials or a personal access token, never both:

- **GitHub App**: `app_client_id` + `app_installation_id` +
  (`app_private_key_path` or `app_private_key`)
- **PAT**: `token`

### Wizard vs Editor

- **Wizard** (`WizardView`) -- Shown on first launch when the config file is
  missing or has empty required fields. Walks the user through 5 steps with
  validation at each step. Saves on completion and starts the runner.

- **Editor** (`ConfigEditorView`) -- Available anytime from the menu bar.
  Tabbed interface for all settings. Autosaves on every change and
  automatically restarts the runner if it was running.

---

## 9. Build System

The `Makefile` orchestrates all builds. The project produces two independent
binaries from separate codebases (Go and Swift) and assembles them into a
standard macOS `.app` bundle.

### Targets

| Target | Command | What it does |
|--------|---------|-------------|
| `build-cli` | `go build -o build/graftery .` | Compiles the standalone Go CLI binary |
| `build-swift` | `cd ConfigUI && swift build -c release` | Compiles the Swift macOS app executable |
| `build-app` | (depends on build-cli + build-swift) | Assembles the `.app` bundle, copies binaries and resources, ad-hoc codesigns |
| `build-dmg` | `./packaging/build-dmg.sh` | Creates a drag-and-drop DMG installer using `create-dmg` (or falls back to `hdiutil`) |
| `install` | Copies `.app` to `/Applications` | Local testing convenience |
| `clean` | Removes `build/` and Swift package cache | |

### App bundle structure

```
build/Graftery.app/
  Contents/
    Info.plist                          # Bundle metadata
    MacOS/
      Graftery                        # Swift executable (from ConfigUI)
    Resources/
      graftery-cli              # Go binary (the engine)
      AppIcon.icns                      # Application icon
      StatusBarIconTemplate.png         # Menu bar icon
      StatusBarIconTemplate@2x.png      # Menu bar icon (Retina)
```

Key details from `Info.plist`:

- `CFBundleIdentifier`: `com.diranged.graftery`
- `LSUIElement`: `true` -- the app runs as a menu bar agent with no Dock icon
- `LSMinimumSystemVersion`: `14.0` (macOS Sonoma)
- `CFBundleExecutable`: `Graftery` (the Swift binary)

The Go CLI binary is placed in `Contents/Resources/`, not `Contents/MacOS/`.
`RunnerManager.cliBinaryPath` locates it via `Bundle.main.resourcePath`.

### Icon generation

`packaging/generate-icons.sh` creates `AppIcon.icns` from a source PNG (or
generates a placeholder). It uses `sips` to resize to all required dimensions
and `iconutil` to produce the `.icns` file.

---

## 10. Key Design Decisions

### Why two processes (Swift app + Go CLI)?

The core scaling logic depends on `github.com/actions/scaleset`, a Go library
with no Swift equivalent. Rather than attempting CGO bridging or reimplementing
the protocol in Swift, the project keeps the Go binary as a standalone CLI and
wraps it with a native SwiftUI app. This gives:

- **Full access to the Go ecosystem** -- the scaleset library, cobra, slog,
  and the broader Go toolchain work unchanged.
- **Native macOS UI** -- SwiftUI provides a polished menu bar experience,
  proper window management, and system integration without CGO complexity.
- **Independent testing** -- the Go CLI works standalone on the command line
  for headless/CI use, server deployments, or launchd integration. The Swift
  app adds a GUI layer without altering the engine.

### Why SwiftUI MenuBarExtra?

`MenuBarExtra` (macOS 13+) is Apple's first-party API for menu bar apps. It
integrates naturally with SwiftUI's declarative model, supports `Window` scenes
for auxiliary windows, and avoids third-party dependencies like `menuet`. The
`LSUIElement=true` plist key ensures the app has no Dock presence -- it lives
entirely in the menu bar.

### Why not CGO for the GUI?

CGO links Go code with C/Objective-C, which can then call AppKit. However:

- CGO complicates cross-compilation and reproducible builds.
- The AppKit/SwiftUI bridge through CGO is fragile and poorly documented.
- SwiftUI's `@Observable`/`@Published` patterns map naturally to subprocess
  output monitoring, which is awkward to model through CGO callbacks.
- The two-process model gives clean separation of concerns.

### Why shell out to `tart` instead of using a library?

Tart does not expose a stable Go library API. The `tart` CLI is the supported
interface, and shelling out to it (`exec.CommandContext`) is the approach used
by other integrations (CircleCI, GitLab). The `tart.go` wrapper keeps all
subprocess calls in one file, making it straightforward to replace if a library
becomes available.

### Why YAML for configuration?

YAML is human-readable and editable with any text editor. Both Go (`gopkg.in/yaml.v3`)
and Swift (`Yams`) have mature YAML libraries. Using the same file format with
matching field names (`snake_case` keys via struct tags and `CodingKeys`) means
the Swift UI and Go engine always agree on config structure without an
intermediate translation layer.

### Why ephemeral single-job VMs?

Each VM runs exactly one job and is destroyed. This ensures:

- **Clean environments** -- no state leaks between jobs.
- **Simple state management** -- no need to track job assignments or reset VMs.
- **Alignment with GitHub's JIT model** -- JIT runner configs are single-use by
  design.

The tradeoff is clone latency per job, which is mitigated by the `min_runners`
warm pool setting.
