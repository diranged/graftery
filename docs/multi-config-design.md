# Multi-Configuration Runner Management — Design Doc

## Context

The CLI supports one runner configuration per process. Users who want multiple runner types (e.g., macos-xcode16, macos-xcode15) run multiple CLI instances with separate config files. The macOS menu bar app currently mirrors this single-config model with one `RunnerManager` and one `config.yaml`.

This redesign makes the macOS app a multi-runner manager: each configuration is a named profile with its own config file, Go subprocess, and log buffer. Users create, enable/disable, and manage multiple configurations from a single menu bar app.

## Decisions

- **Storage**: One YAML file per config in `~/Library/Application Support/graftery/configs/`
- **Auto-start**: Each config has an `enabled` flag. Only enabled configs auto-start on launch.
- **Menu bar**: Grouped list showing each config's status with individual start/stop buttons.
- **No Go changes**: Each Go subprocess is independent — the Swift app just passes `--config <path>` per process.

---

## UI Design

### Menu Bar Icon (collapsed)

```
┌──────────────────────────────────┐
│ [▶] Graftery                   │
└──────────────────────────────────┘
```

### Menu Bar Dropdown — Normal Operation

```
┌──────────────────────────────────────┐
│  Graftery v0.1.0                   │
│──────────────────────────────────────│
│  macos-xcode16         Running       │
│    [Stop]                            │
│  macos-xcode15         Idle          │
│    [Start]                           │
│  macos-base            Disabled      │
│    [Enable & Start]                  │
│──────────────────────────────────────│
│  New Configuration...          ⌘N    │
│  Manage Configurations...      ⌘,    │
│──────────────────────────────────────│
│  Stop All                            │
│  Quit Graftery               ⌘Q   │
└──────────────────────────────────────┘
```

Each config shows its name and state. The action button is contextual:
- **Running/Starting** → `[Stop]`
- **Idle/Error (enabled)** → `[Start]`
- **Disabled** → `[Enable & Start]`

### Menu Bar Dropdown — First Launch (no configs)

```
┌──────────────────────────────────────┐
│  Graftery v0.1.0                   │
│──────────────────────────────────────│
│  No configurations yet               │
│──────────────────────────────────────│
│  New Configuration...          ⌘N    │
│──────────────────────────────────────│
│  Quit Graftery               ⌘Q   │
└──────────────────────────────────────┘
```

### Menu Bar Dropdown — Tart Not Found

```
┌──────────────────────────────────────┐
│  Graftery v0.1.0                   │
│──────────────────────────────────────│
│  ⚠ Tart not found                   │
│    brew install cirruslabs/cli/tart  │
│    [Locate Tart...]                  │
│    [Re-check for Tart]               │
│──────────────────────────────────────│
│  Quit Graftery               ⌘Q   │
└──────────────────────────────────────┘
```

Tart warning shows at the top level (system-wide dependency), blocks all configs.

---

### Configuration Manager Window (`⌘,`)

The primary management surface. Table of all configurations.

```
┌──────────────────────────────────────────────────────────┐
│  Graftery — Configurations                      ─ □ ✕ │
│──────────────────────────────────────────────────────────│
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Name             │ Enabled │ Status  │ Actions     │  │
│  │──────────────────│─────────│─────────│─────────────│  │
│  │ macos-xcode16    │  [✓]    │ Running │ Edit Logs ✕ │  │
│  │ macos-xcode15    │  [ ]    │ Idle    │ Edit Logs ✕ │  │
│  │ macos-base       │  [✓]    │ Error   │ Edit Logs ✕ │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  [+ New Configuration]                    [Stop All]     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

- **Enabled toggle**: Flips the `enabled` flag. Disabled configs don't auto-start.
- **Status**: Real-time from `RunnerManager.state` (Idle, Starting, Running, Stopping, Error)
- **Edit**: Opens the config editor window focused on this config
- **Logs**: Opens the log viewer window focused on this config
- **✕ (Delete)**: Confirmation dialog, stops runner, deletes config file

---

### Configuration Editor Window

Same tabbed editor as today, but with a config picker at the top for switching between configs without closing the window.

```
┌──────────────────────────────────────────────────────────┐
│  Graftery — Edit Configuration                  ─ □ ✕ │
│──────────────────────────────────────────────────────────│
│  Config: [ macos-xcode16      ▾ ]    ← picker to switch │
│──────────────────────────────────────────────────────────│
│  ┌────────┬──────┬─────────┬──────────┬─────────┬─────┐ │
│  │ General│ Auth │ Runners │Provision │ Logging │About│ │
│  └────────┴──────┴─────────┴──────────┴─────────┴─────┘ │
│                                                          │
│  Registration URL:                                       │
│  ┌──────────────────────────────────────────────────┐    │
│  │ https://github.com/Sproutbook                    │    │
│  └──────────────────────────────────────────────────┘    │
│  The GitHub org or repo URL for scale set registration.  │
│                                                          │
│  Scale Set Name:                                         │
│  ┌──────────────────────────────────────────────────┐    │
│  │ wiredgeek-macos                                  │    │
│  └──────────────────────────────────────────────────┘    │
│  Also used as the runs-on label in workflows.            │
│                                                          │
│  ...                                                     │
│                                                          │
│  ✓ Changes saved                                         │
└──────────────────────────────────────────────────────────┘
```

---

### Log Viewer Window

Same log viewer as today, with a config picker at the top.

```
┌──────────────────────────────────────────────────────────┐
│  Graftery — Logs                                ─ □ ✕ │
│──────────────────────────────────────────────────────────│
│  Config: [ macos-xcode16      ▾ ]    ← picker to switch │
│──────────────────────────────────────────────────────────│
│  🔍 Filter logs...    Level [All ▾]  ☑ Auto-scroll   🗑 │
│──────────────────────────────────────────────────────────│
│  14:47:03  INFO   guest agent ready, boot_duration=12s   │
│  14:47:03  INFO   VM network check passed duration=800ms │
│  14:47:04  INFO   √ Connected to GitHub                  │
│  14:47:05  INFO   Running job: Build iOS App             │
│  14:47:45  WARN   job completed result=failed            │
│  14:47:45  INFO   runner cleaned up lifetime=1m0s        │
│──────────────────────────────────────────────────────────│
│  247 lines                                               │
└──────────────────────────────────────────────────────────┘
```

---

### Setup Wizard — Step 1 (New: Name)

First step asks for a configuration name before proceeding to the existing 5-step wizard.

```
┌──────────────────────────────────────────────────────────┐
│  Graftery Setup                                 ─ □ ✕ │
│──────────────────────────────────────────────────────────│
│                                                          │
│           ▶ Graftery                                   │
│                                                          │
│  Step 1 of 6: Name Your Configuration                    │
│                                                          │
│  Configuration Name:                                     │
│  ┌──────────────────────────────────────────────────┐    │
│  │ macos-xcode16                                    │    │
│  └──────────────────────────────────────────────────┘    │
│  Used as the filename and display name.                  │
│  Letters, numbers, and hyphens only.                     │
│                                                          │
│                                                          │
│                                          [Next →]        │
│──────────────────────────────────────────────────────────│
│  ● ○ ○ ○ ○ ○                                            │
└──────────────────────────────────────────────────────────┘
```

Steps 2-6 are the existing wizard steps (GitHub URL, Auth, VM Settings, Runner Settings, Logging), renumbered.

---

## Data Model

### File Layout

```
~/Library/Application Support/graftery/
├── configs/
│   ├── macos-xcode16.yaml       # standard AppConfig YAML
│   ├── macos-xcode15.yaml
│   └── macos-base.yaml
├── runner-state.json             # Swift-only metadata
├── scripts/                      # shared user override scripts
│   ├── bake.d/
│   └── hooks/
│       ├── pre.d/
│       └── post.d/
└── prepared-images/
    ├── arc-prepared-macos-runner-sonoma.hash
    └── ...
```

### runner-state.json

Swift-only file tracking which configs exist and their enabled state. Not read by Go.

```json
{
  "configs": [
    {"name": "macos-xcode16", "enabled": true},
    {"name": "macos-xcode15", "enabled": false},
    {"name": "macos-base", "enabled": true}
  ]
}
```

### Key Types

```swift
// RunnerStore — manages the collection of runner configs
@MainActor
class RunnerStore: ObservableObject {
    @Published var instances: [RunnerInstance] = []
    @Published var selectedConfigName: String? = nil
    @Published var needsFirstRunWizard: Bool = false
    
    func loadAll()                    // scan configs/, migrate, create instances
    func addConfig(name:)             // create new config file + instance
    func removeConfig(name:)          // stop, delete file, remove instance
    func toggleEnabled(name:)         // flip enabled, start/stop accordingly
    func startAllEnabled()
    func stopAll() async
    func instance(named:) -> RunnerInstance?
    func saveState()                  // persist runner-state.json
}

// RunnerInstance — one config + its subprocess + its logs
class RunnerInstance: Identifiable, ObservableObject {
    let name: String                  // matches filename stem
    let configPath: String            // full path to YAML file
    let manager: RunnerManager        // owns the Go subprocess
    let logStore: LogStore            // per-config log buffer
    @Published var enabled: Bool
}
```

### RunnerManager Changes

```swift
// Before (single config):
init() { autoStartOrWizard() }
var configPath: String { AppConfig.defaultPath }  // computed, hardcoded

// After (multi config):
init(configPath: String, configName: String) { ... }
let configPath: String   // stored, passed in
let configName: String   // for display
let logStore: LogStore    // owned, not injected
// No auto-start, no needsWizard — RunnerStore controls lifecycle
```

---

## Migration (single → multi config)

On first launch with multi-config support:

1. If `configs/` directory exists → load normally
2. If `configs/` doesn't exist but `config.yaml` exists at root:
   - Create `configs/` directory
   - Copy `config.yaml` → `configs/default.yaml`
   - Create `runner-state.json` with `[{name: "default", enabled: true}]`
   - Rename `config.yaml` → `config.yaml.migrated`
3. If neither exists → show first-run wizard

---

## Window Management

SwiftUI requires compile-time `Window` scene IDs. We use four static windows with a selection-based routing pattern:

| Window ID | View | How it knows which config |
|-----------|------|--------------------------|
| `"config-manager"` | `ConfigManagerView` | Shows all configs |
| `"config-editor"` | `ConfigEditorWrapper` → `ConfigEditorView` | Reads `store.selectedConfigName` + has a picker to switch |
| `"logs"` | `LogViewerWrapper` → `LogViewerView` | Reads `store.selectedConfigName` + has a picker to switch |
| `"wizard"` | `WizardView` | Creates a new config, returns the name |

**Flow**: User clicks "Edit" in manager or menu → `store.selectedConfigName = "that-config"` → `openWindow(id: "config-editor")`.

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `ConfigUI/Sources/RunnerStore.swift` | **New** — collection manager, migration, state persistence |
| `ConfigUI/Sources/RunnerInstance.swift` | **New** — per-config container (manager + logStore + metadata) |
| `ConfigUI/Sources/ConfigManagerView.swift` | **New** — table of configs with enable/edit/delete |
| `ConfigUI/Sources/ConfigEditorWrapper.swift` | **New** — resolves selected config → ConfigEditorView |
| `ConfigUI/Sources/LogViewerWrapper.swift` | **New** — resolves selected config → LogViewerView |
| `ConfigUI/Sources/RunnerManager.swift` | **Modify** — parameterized init, remove auto-start/wizard |
| `ConfigUI/Sources/ConfigUIApp.swift` | **Modify** — RunnerStore replaces RunnerManager, new menu/windows |
| `ConfigUI/Sources/Config.swift` | **Modify** — add `configPath(forName:)` helper |
| `ConfigUI/Sources/WizardView.swift` | **Modify** — add name step (step 1 of 6) |
| `ConfigUI/Sources/ConfigEditorView.swift` | **Minor** — accept configName for display |

No Go changes needed.

---

## Verification

1. **Fresh install**: Launch app → wizard opens → name a config → complete wizard → config appears in menu bar → starts automatically
2. **Migration**: Place old `config.yaml` at root → launch app → migrated to `configs/default.yaml` → appears in menu/manager
3. **Multiple configs**: Create 2+ configs via wizard → both appear in menu bar → individual start/stop works
4. **Enable/disable**: Toggle enabled in manager → disabled configs don't auto-start on next launch
5. **Editor**: Click Edit in manager → editor opens with correct config → changes auto-save → runner restarts
6. **Logs**: Click Logs in manager → log viewer shows correct config's logs → picker switches between configs
7. **Delete**: Delete a config → confirmation → runner stops → file removed → disappears from UI
8. **Stop All / Quit**: All runners stop cleanly on quit
