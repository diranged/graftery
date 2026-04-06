# graftery

A lightweight CLI that connects GitHub Actions to ephemeral macOS VMs via
[Tart](https://tart.run) and the
[actions/scaleset](https://github.com/actions/scaleset) library — the same
scale-set protocol that ARC uses inside Kubernetes, but running directly on a
Mac host.

## How it works

```
GitHub Actions                        Mac Host
─────────────                         ────────
                                      graftery (this binary)
  workflow_job ──► Scale Set API ──►    ├─ listener (long-poll)
                                        ├─ HandleDesiredRunnerCount
                                        │    tart clone base → runner-xxxx
                                        │    tart run --no-graphics runner-xxxx
                                        │    (JIT config injected via shared dir)
                                        ├─ HandleJobStarted
                                        │    mark runner busy
                                        └─ HandleJobCompleted
                                             tart stop runner-xxxx
                                             tart delete runner-xxxx
```

## Architecture

The program is a single long-running process with three layers:

1. **CLI + Config** — cobra flags, validation, client construction.
   Near-identical to the upstream `dockerscaleset` example.

2. **Listener** — provided entirely by `actions/scaleset/listener`.
   Long-polls GitHub for job demand, dispatches to the Scaler interface.

3. **Scaler (Tart)** — implements `listener.Scaler`. This is the only layer
   that differs from the Docker example. It shells out to the `tart` CLI.

### Scaler lifecycle

| Callback                   | Action                                                |
|----------------------------|-------------------------------------------------------|
| `HandleDesiredRunnerCount` | For each runner needed: generate JIT config, `tart clone`, `tart run` in a background goroutine |
| `HandleJobStarted`         | Move runner from idle → busy in state map             |
| `HandleJobCompleted`       | `tart stop` + `tart delete`, remove from state map    |

### VM lifecycle (per runner)

```
1.  tart clone <base-image> runner-<uuid8>
2.  Write JIT config to a temp dir
3.  tart run --no-graphics --dir=<tempdir>:shared runner-<uuid8>
      └─ runs in a background goroutine
      └─ blocks until VM shuts down
4.  Inside the VM:
      - Startup script reads ACTIONS_RUNNER_INPUT_JITCONFIG from shared dir
      - Starts /Users/admin/actions-runner/run.sh
      - Runner picks up one job (ephemeral mode via JIT)
      - Runner exits → VM auto-shuts down (configured in base image)
5.  tart run returns → goroutine calls tart delete runner-<uuid8>
```

### Crash recovery

On startup, before creating the scale set:

1. `tart list --format json` — find any VMs matching prefix `runner-`
2. `tart stop <name>` + `tart delete <name>` for each orphan
3. Log what was cleaned up

This is intentionally simple. Orphaned VMs are killed, and GitHub
automatically retries the jobs they were running. No state file needed.

## CLI interface

```
graftery \
  --url        https://github.com/Sproutbook \
  --name       sproutbook-macos \
  --app-client-id      <github-app-client-id> \
  --app-installation-id 113043096 \
  --app-private-key-path /path/to/private-key.pem \
  --base-image macos-ci-base \
  --max-runners 2 \
  --min-runners 0 \
  --log-level  info
```

### Flags

| Flag                       | Required | Default            | Description                                    |
|----------------------------|----------|--------------------|------------------------------------------------|
| `--url`                    | yes      |                    | GitHub org or repo URL for scale set registration |
| `--name`                   | yes      |                    | Scale set name (also the `runs-on:` label)     |
| `--app-client-id`          | *        |                    | GitHub App Client ID                           |
| `--app-installation-id`    | *        |                    | GitHub App Installation ID                     |
| `--app-private-key-path`   | *        |                    | Path to PEM file (avoids key on command line)   |
| `--token`                  | *        |                    | PAT (alternative to GitHub App)                |
| `--base-image`             | yes      |                    | Tart VM image name to clone for each runner    |
| `--max-runners`            | no       | 2                  | Max concurrent VMs (Apple allows max 2 macOS)  |
| `--min-runners`            | no       | 0                  | Warm pool size                                 |
| `--labels`                 | no       | (same as --name)   | Additional labels for workflow targeting        |
| `--runner-group`           | no       | default            | GitHub runner group name                       |
| `--runner-prefix`          | no       | runner             | VM name prefix (used for orphan detection)     |
| `--log-level`              | no       | info               | debug, info, warn, error                       |
| `--log-format`             | no       | text               | text or json                                   |

*Either GitHub App credentials or `--token` is required.

## File structure

```
graftery/
  go.mod
  go.sum
  main.go           # CLI entry point (build tag: !gui)
  main_gui.go       # macOS menu bar app entry point (build tag: gui)
  run.go            # Shared run() function — core lifecycle
  config.go         # Config struct, validation, client construction
  configfile.go     # YAML config file loading/saving
  status.go         # AppStatus — observable state for UI
  scaler.go         # Scaler implementation (Tart VM lifecycle)
  tart.go           # Thin wrapper: clone, run, stop, delete, list
  logging.go        # File-based logging for GUI build (build tag: gui)
  Makefile          # build-cli, build-app, build-dmg targets
  packaging/
    Info.plist        # App bundle metadata (LSUIElement for menu-bar-only)
    generate-icons.sh # Creates AppIcon.icns from a source PNG
    build-dmg.sh      # Creates drag-and-drop DMG installer
```

### Build modes

The project produces two binaries from the same package using build tags:

- **CLI** (`go build .`): Pure Go, no CGO. Same cobra-based CLI as before.
- **macOS App** (`go build -tags gui .`): CGO enabled, links Cocoa via
  `menuet`. Runs as a menu bar item with no Dock icon.

Use `make build-cli` or `make build-app` respectively.

## Base VM image requirements

The Tart base image must have:

1. **GitHub Actions runner binary** installed at a known path
   (e.g. `/Users/admin/actions-runner/`)
2. **A startup script** that reads JIT config from the shared directory mount
   and starts the runner
3. **Auto-shutdown on runner exit** — when `run.sh` exits, the VM powers off
   so `tart run` returns

Image creation (Packer template, etc.) is out of scope for this tool and will
be handled separately.

## What this tool does NOT do

- Build or manage VM images (use Packer + tart plugin)
- Install itself as a system service (use launchd, managed separately)
- Push/pull images from OCI registries (use `tart clone`/`tart push`)
- Manage multiple orgs simultaneously (run multiple instances)

## macOS App

The GUI build produces a standard `.app` bundle:

```
Graftery.app/
  Contents/
    Info.plist          # LSUIElement=true (menu bar only, no Dock icon)
    MacOS/
      graftery  # The compiled binary
    Resources/
      AppIcon.icns      # Application icon
```

### Menu bar

```
[ARC: 1/2]                    ← status bar (busy/total runners)
├── Status: Running
├── Runners: 1 idle, 1 busy
├── ─────────────────
├── Stop
├── ─────────────────
├── Open Config File           ← opens ~/Library/Application Support/.../config.yaml
├── Open Logs                  ← opens log in Console.app
├── Reload Config
├── ─────────────────
└── Quit
```

### Config file

The GUI app reads configuration from YAML instead of CLI flags:

```
~/Library/Application Support/graftery/config.yaml
```

A default config file is created on first launch. Logs go to:

```
~/Library/Logs/graftery/graftery.log
```

### Installation

```bash
make build-app    # Build the .app bundle
make build-dmg    # Create a drag-and-drop DMG
make install      # Copy to /Applications
```

## Dependencies

- Go 1.25+
- `github.com/actions/scaleset` — scale set client + listener
- `github.com/spf13/cobra` — CLI flags
- `github.com/google/uuid` — runner name generation
- `github.com/caseymrm/menuet` — macOS menu bar (GUI build only)
- `gopkg.in/yaml.v3` — config file parsing
- `tart` binary in PATH — VM operations
