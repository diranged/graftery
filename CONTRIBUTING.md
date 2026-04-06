# Contributing to graftery

This guide covers everything you need to build, test, and develop the project locally.

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| **Go** | 1.26+ | CLI binary and core logic |
| **Swift** | 5.9+ | macOS menu-bar app (ConfigUI) |
| **Xcode Command Line Tools** | Latest | Required for Swift compilation and `iconutil` |
| **Tart** | Latest | VM runtime; needed to test runner lifecycle (`brew install cirruslabs/cli/tart`) |
| **create-dmg** | Latest | Optional, for prettier DMG packaging (`brew install create-dmg`) |

Verify your setup:

```bash
go version          # go1.26.x or later
swift --version     # Swift 5.9 or later
xcode-select -p     # should print a path (run xcode-select --install if missing)
tart --version      # needed for end-to-end testing only
```

## Project Structure

```
graftery/
  main.go              # CLI entry point (cobra command, flag binding)
  run.go               # Shared run() function — core lifecycle (config -> client -> listener)
  config.go            # Config struct, Validate(), client construction, logger factory
  configfile.go        # YAML config file load/save/ensure (~/Library/Application Support/...)
  scaler.go            # TartScaler — implements listener.Scaler using Tart VMs
  tart.go              # Thin wrappers around the tart CLI (clone, run, stop, delete, list)
  status.go            # AppStatus — thread-safe observable state for UI layer
  logging.go           # File-based logging setup (gui build tag)
  oslog.go             # macOS unified logging bridge (gui build tag)
  main_gui.go          # macOS menu-bar app entry point (gui build tag)
  multihandler.go      # slog multi-handler for writing to file + os_log simultaneously
  go.mod / go.sum      # Go module definition

  ConfigUI/            # Swift macOS app (SwiftUI menu-bar application)
    Package.swift      # Swift package manifest (depends on Yams for YAML parsing)
    Sources/
      ConfigUIApp.swift       # @main App — MenuBarExtra, window scenes, app delegate
      Config.swift            # AppConfig struct (mirrors Go Config, YAML coding keys)
      RunnerManager.swift     # Manages the Go CLI as a subprocess (Process)
      ConfigEditorView.swift  # Tabbed settings editor (General, Auth, Runners, Logging, About)
      WizardView.swift        # First-launch setup wizard (5-step flow)
      LogViewerView.swift     # Live log viewer using macOS `log stream`

  packaging/
    Info.plist             # App bundle metadata (LSUIElement=true for menu-bar-only)
    generate-icons.sh      # Creates AppIcon.icns from a source PNG (or generates placeholder)
    build-dmg.sh           # Creates drag-and-drop DMG installer
    AppIcon.icns           # Pre-built app icon
    StatusBarIconTemplate.png      # Menu bar icon (1x)
    StatusBarIconTemplate@2x.png   # Menu bar icon (2x Retina)

  Makefile             # Build targets: build-cli, build-swift, build-app, build-dmg, clean, install
  build/               # Build output directory (git-ignored)
```

## Building

### CLI only (Go binary)

```bash
make build-cli
# or directly:
go build -o build/graftery .
```

This produces `build/graftery`, a standalone binary with no CGO dependencies.

### Swift app only

```bash
cd ConfigUI && swift build
# or release mode:
cd ConfigUI && swift build -c release
```

The first build will fetch the [Yams](https://github.com/jpsim/Yams) dependency. The output lands in `ConfigUI/.build/`.

### Full .app bundle

```bash
make build-app
```

This runs both `build-cli` and `build-swift`, then assembles the bundle at `build/Graftery.app/`:

```
Graftery.app/
  Contents/
    Info.plist
    MacOS/
      Graftery           # Swift binary (the main executable)
    Resources/
      graftery-cli # Go binary (launched as a subprocess by Swift)
      AppIcon.icns
      StatusBarIconTemplate.png
      StatusBarIconTemplate@2x.png
```

The Makefile also runs `codesign --force --deep --sign -` for ad-hoc signing.

### DMG installer

```bash
make build-dmg
```

Requires `build-app` to have run first (it is a dependency). If `create-dmg` is installed, you get a styled drag-and-drop DMG. Otherwise, it falls back to `hdiutil` for a basic DMG. Output: `build/Graftery.dmg`.

### Clean

```bash
make clean
```

Removes `build/` and runs `swift package clean` inside ConfigUI.

## Development Workflow

### Go changes (CLI / core logic)

1. Edit the Go source files.
2. Build and run:
   ```bash
   go build -o build/graftery . && ./build/graftery --config /path/to/config.yaml
   ```
3. The CLI accepts all configuration via flags too, so you can skip the config file:
   ```bash
   ./build/graftery \
     --url https://github.com/my-org \
     --name my-runner \
     --token ghp_xxxx \
     --base-image macos-ci-base \
     --log-level debug
   ```

### Swift changes (ConfigUI app)

1. Edit Swift files under `ConfigUI/Sources/`.
2. Quick iteration with just Swift:
   ```bash
   cd ConfigUI && swift build
   ```
3. To test the full app (Swift launching the Go subprocess):
   ```bash
   make build-app
   open "build/Graftery.app"
   ```
4. The app reads config from `~/Library/Application Support/graftery/config.yaml`. On first launch it opens a setup wizard if no valid config exists.

### Hot reload tips

- **Go**: There is no built-in hot reload. Use a file-watcher if desired:
  ```bash
  # Using entr (brew install entr):
  ls *.go | entr -r go run . --config /path/to/config.yaml
  ```
- **Swift**: Xcode provides live previews for SwiftUI views. Open `ConfigUI/Package.swift` in Xcode to get preview support. Note that previews work for the UI views but `RunnerManager` needs the Go binary present to function.
- **Config changes**: The Swift app autosaves config edits and restarts the Go subprocess automatically. No rebuild needed for config-only changes.

## Architecture Notes

### Two-process design

The project uses a two-process architecture:

1. **Swift app** (`Graftery` / `Graftery`) — The macOS menu-bar application built with SwiftUI. It provides the UI (menu bar item, config editor, setup wizard, log viewer) and manages the lifecycle of the Go process.

2. **Go CLI** (`graftery-cli`) — The headless runner engine. It connects to GitHub via the `actions/scaleset` library, listens for job demand, and orchestrates Tart VMs.

### How Swift launches Go

`RunnerManager.swift` locates the Go binary using two strategies:
- **In the app bundle**: `Bundle.main.resourcePath` + `/graftery-cli`
- **Development fallback**: next to the running executable

It launches the binary as a `Process` (subprocess) with `--config <path>` and captures stdout/stderr through a pipe. The Swift app monitors log output to detect state transitions (e.g., detecting "listener starting" in the output to move from Starting to Running state).

SIGINT is sent for graceful shutdown (`process.interrupt()`).

### How config flows

1. The Swift UI writes config to `~/Library/Application Support/graftery/config.yaml` (YAML format, using Yams).
2. The Go CLI reads the same file via `--config` flag, unmarshals it with `gopkg.in/yaml.v3`.
3. Both sides use matching YAML keys (e.g., `app_client_id`, `base_image`, `max_runners`). The Swift `AppConfig.CodingKeys` enum and Go `Config` struct yaml tags must stay in sync.

### Core Go flow

```
main.go  ->  run.go: run(ctx, cfg, status)
                |
                +-- cfg.Validate()
                +-- cfg.ScalesetClient()         // create GitHub API client
                +-- client.CreateRunnerScaleSet() // register with GitHub
                +-- TartScaler.CleanupOrphans()   // kill leftover VMs
                +-- listener.New() + listener.Run() // long-poll for jobs
                        |
                        +-- HandleDesiredRunnerCount -> tart clone + tart run (goroutine)
                        +-- HandleJobStarted         -> mark runner busy
                        +-- HandleJobCompleted       -> tart delete, cleanup
```

## Testing

### Local testing requirements

To test end-to-end, you need:

1. **A GitHub App** (or PAT) with permissions to manage self-hosted runners on your org/repo.
2. **A Tart base image** that has the GitHub Actions runner installed with a startup script that reads JIT config from the shared directory mount. See the base image requirements in DESIGN.md.
3. **Tart installed** and working (`tart list` should succeed).

### Running the CLI manually

```bash
# Build
make build-cli

# Run with a config file
./build/graftery --config ~/Library/Application\ Support/graftery/config.yaml

# Or with flags
./build/graftery \
  --url https://github.com/my-org \
  --name test-runner \
  --app-client-id Iv1.xxx \
  --app-installation-id 12345 \
  --app-private-key-path /path/to/key.pem \
  --base-image my-macos-image \
  --max-runners 1 \
  --log-level debug
```

### Testing the Swift app

```bash
make build-app
open "build/Graftery.app"
```

The app appears as a menu-bar icon (no Dock icon, due to `LSUIElement=true` in Info.plist). Use the menu to open Configuration, view Logs, start/stop the runner.

### What to watch for

- **Orphan VMs**: If the process crashes, VMs may be left behind. The next startup cleans them up automatically (`CleanupOrphans`), but you can also run `tart list` and `tart delete <name>` manually.
- **Apple VM limit**: Apple Silicon allows a maximum of 2 concurrent macOS VMs. Setting `--max-runners` higher than 2 will cause `tart run` failures.
- **Scale set registration**: Each run creates a scale set with GitHub and deletes it on shutdown. If the process is killed without cleanup, the stale scale set will be overwritten on next start (same name).
- **Log output**: Use `--log-level debug` for verbose output. The Swift app streams logs from macOS unified logging (`log stream --predicate 'subsystem == "com.diranged.graftery"'`).

## Adding Config Fields

When adding a new configuration option, you need to update both the Go and Swift sides. Here is the step-by-step process:

### 1. Add to the Go `Config` struct

In `config.go`, add the field with a `yaml` struct tag:

```go
type Config struct {
    // ... existing fields ...
    MyNewField string `yaml:"my_new_field"`
}
```

### 2. Set the default value

Update the default config in `main.go` (for CLI defaults), `configfile.go` (`LoadConfigFile` and `EnsureConfigFile` functions), and optionally add a CLI flag in `main.go`:

```go
flags.StringVar(&cfg.MyNewField, "my-new-field", "default-value", "Description of the field")
```

### 3. Add validation (if needed)

Add validation logic in `config.go` inside the `Validate()` method.

### 4. Add to Swift `AppConfig`

In `ConfigUI/Sources/Config.swift`, add the property and coding key:

```swift
struct AppConfig: Codable, Equatable {
    // ... existing fields ...
    var myNewField: String = "default-value"

    enum CodingKeys: String, CodingKey {
        // ... existing keys ...
        case myNewField = "my_new_field"
    }
}
```

The `CodingKeys` value **must match** the Go yaml tag exactly.

### 5. Add to the UI

Depending on which tab the field belongs to, edit the appropriate section in `ConfigUI/Sources/ConfigEditorView.swift`:

```swift
TextField("My New Field", text: $config.myNewField, prompt: Text("default-value"))
fieldHint("Description of what this field does.")
```

If the field should appear in the first-launch wizard, also add it to the relevant step in `ConfigUI/Sources/WizardView.swift`.

### 6. Verify round-trip

Build both sides and confirm:
- The Go CLI reads the new field from YAML correctly.
- The Swift app displays, edits, and saves the field without data loss.
- Existing config files without the new field still load (the default value is used).

## Packaging

### App bundle structure

The `.app` bundle follows the standard macOS layout:

```
Graftery.app/
  Contents/
    Info.plist                          # Bundle metadata
    MacOS/
      Graftery                        # Main executable (Swift, the CFBundleExecutable)
    Resources/
      graftery-cli              # Go binary (launched as subprocess)
      AppIcon.icns                      # App icon
      StatusBarIconTemplate.png         # Menu bar icon (1x, template image)
      StatusBarIconTemplate@2x.png      # Menu bar icon (2x)
```

Key Info.plist settings:
- `LSUIElement = true` — app runs in the menu bar only, no Dock icon
- `LSMinimumSystemVersion = 14.0` — requires macOS 14 Sonoma or later
- `CFBundleExecutable = Graftery` — points to the Swift binary

### Regenerating the app icon

```bash
# From a custom 1024x1024 PNG:
./packaging/generate-icons.sh /path/to/my-icon-1024x1024.png

# Or generate a placeholder (blue circle):
./packaging/generate-icons.sh
```

The script uses `sips` to resize and `iconutil` to convert the iconset to `.icns`. Both tools ship with macOS. The generated `packaging/AppIcon.icns` is copied into the bundle by `make build-app`.

### Code signing

The Makefile applies **ad-hoc signing** during `build-app`:

```bash
codesign --force --deep --sign - "build/Graftery.app"
```

This is sufficient for local development and testing. For distribution:

1. Replace `-` with your Developer ID certificate identity:
   ```bash
   codesign --force --deep --sign "Developer ID Application: Your Name (TEAMID)" "build/Graftery.app"
   ```
2. For notarization, submit the signed app or DMG to Apple:
   ```bash
   xcrun notarytool submit build/Graftery.dmg --apple-id you@example.com --team-id TEAMID --password @keychain:AC_PASSWORD
   ```

### Installing locally

```bash
make install      # copies Graftery.app to /Applications
make uninstall    # removes it
```

## Common Issues

### Go build failures

- **`go: module not found`**: Run `go mod download` to fetch dependencies. The project depends on `github.com/actions/scaleset` which may require `GOPRIVATE` if the repo is not yet public.
- **Wrong Go version**: The project requires Go 1.26+. Check with `go version`.

### Swift package resolution

- **`error: package resolution failed`**: Delete the cache and retry:
  ```bash
  cd ConfigUI
  rm -rf .build/repositories .build/checkouts
  swift package resolve
  ```
- **Xcode version mismatch**: The package requires Swift 5.9+ (macOS 14 SDK). Make sure `xcode-select -p` points to a compatible Xcode installation.
- **`No such module 'Yams'`**: Run `cd ConfigUI && swift build` at least once to fetch and build the dependency before opening in Xcode.

### App bundle issues

- **"Graftery.app is damaged"**: This usually means the app is not signed. Re-run `make build-app` which includes the ad-hoc `codesign` step. If downloading from another machine, you may need to clear the quarantine flag:
  ```bash
  xattr -cr "build/Graftery.app"
  ```
- **"graftery-cli not found"**: The Swift app could not locate the Go binary. Make sure `make build-app` completed successfully and the binary exists at `build/Graftery.app/Contents/Resources/graftery-cli`.

### Code signing errors

- **`codesign: command not found`**: Install Xcode Command Line Tools: `xcode-select --install`.
- **`errSecInternalComponent`**: Sometimes occurs with Keychain issues. Try locking and unlocking your Keychain, or use ad-hoc signing (`--sign -`).

### Runtime issues

- **`tart: command not found`**: Install Tart (`brew install cirruslabs/cli/tart`) and ensure it is in your PATH.
- **VM creation failures**: Make sure the base image exists locally (`tart list` to check). Pull it first if needed: `tart clone ghcr.io/cirruslabs/macos-runner:sonoma`.
- **"Maximum concurrent macOS VMs exceeded"**: Apple Silicon has a hard limit of 2 macOS VMs. Set `--max-runners 2` or lower.
- **Config file not found**: The default location is `~/Library/Application Support/graftery/config.yaml`. The Swift app creates this on first launch. For CLI use, create it manually or pass `--config /your/path.yaml`.
