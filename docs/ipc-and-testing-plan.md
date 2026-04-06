# IPC, Dry-Run Mode, and UI Testing Plan

## Overview

Three interconnected changes to make the Swift↔Go communication reliable
and the app properly testable:

1. **Unix Domain Socket IPC** — structured HTTP/JSON API between Go CLI and Swift app
2. **Dry-Run Mode** — Go CLI simulates full lifecycle without real GitHub/tart
3. **UI Testing** — XCTest UI tests using dry-run mode to verify app behavior

---

## Part 1: Unix Domain Socket IPC

### Problem

The Swift app detects the Go CLI's state by string-matching pipe output
for `"listener starting"`. This is fragile — the `@MainActor` dispatch,
`weak self` lifecycle, and SwiftUI view refresh timing all conspire to
make the state detection unreliable.

### Solution

Go serves an HTTP/JSON API on a Unix domain socket. Swift polls it.
No more string matching. Bidirectional: Swift can also send commands.

### Go Side

**New file: `control.go`**

```go
// StartControlServer starts an HTTP server on a Unix domain socket.
// The socket path is passed via --control-socket flag.
func StartControlServer(ctx context.Context, socketPath string, status *AppStatus) error
```

Endpoints:

| Method | Path | Request | Response |
|--------|------|---------|----------|
| GET | `/status` | — | `{"state":"running","idle_runners":0,"busy_runners":1,"runners":[{"name":"runner-abc","state":"busy","job":"Build iOS","repo":"org/repo"}]}` |
| GET | `/health` | — | `{"ok":true}` |
| POST | `/stop` | — | `{"ok":true}` (sends SIGINT to self) |

The server:
- Listens on a Unix socket at the path given by `--control-socket`
- Reads from `AppStatus` + `TartScaler.runners` for state
- Removes the socket file on shutdown
- Starts in `run()` before the listener loop

**Config/Flag changes:**
- Add `--control-socket` flag to `main.go`
- Socket path convention: `/tmp/arc-runner-<config-name>.sock`
- The Swift app generates the path and passes it as an argument

**AppStatus changes (`status.go`):**
- Add runner detail tracking (name, state, job context)
- Add `Snapshot()` method that returns a JSON-serializable struct
- Wire into `TartScaler` so job context flows to AppStatus

### Swift Side

**RunnerManager changes:**
- On `start()`: generate socket path, pass `--control-socket <path>` to the process
- Start a polling timer (every 2s) that `GET /status` from the socket
- Parse JSON response → update `@Published state`, runner info, etc.
- On `stop()`: `POST /stop` to socket (cleaner than SIGINT)
- Remove string-matching readability handler for state detection
- Keep pipe handler for LogStore only (log display still works via pipe)

**State detection becomes:**
```swift
// Poll the control socket every 2 seconds
timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    guard let url = controlSocketURL else { return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data, let status = try? JSONDecoder().decode(RunnerStatus.self, from: data) else { return }
        DispatchQueue.main.async {
            self.state = State(rawValue: status.state) ?? self.state
            // ... update runner info ...
        }
    }.resume()
}
```

**URLSession with Unix socket:**
```swift
let config = URLSessionConfiguration.default
// URLSession supports unix sockets via the stream task API or
// by using a custom protocol. Simpler: use NWConnection.
// Actually simplest: shell out to curl or use a raw socket connection.
```

Note: `URLSession` doesn't natively support Unix domain sockets easily.
Options:
- **NWConnection** with `NWEndpoint.unix(path:)` — Apple's Network framework
- **Raw socket** via `Darwin.connect()` — low-level but straightforward
- **Wrap in a helper** that opens the socket and does HTTP manually

Recommendation: Use a small `UnixSocketHTTPClient` helper class (~40 lines)
that opens a Unix socket connection, sends a raw HTTP request, and parses
the response. No external dependencies needed.

### Files Changed

| File | Change |
|------|--------|
| `control.go` | **New** — HTTP server on Unix socket |
| `status.go` | Expand with runner details, Snapshot() |
| `main.go` | Add `--control-socket` flag |
| `run.go` | Start control server before listener |
| `scaler.go` | Push runner/job state to AppStatus |
| `RunnerManager.swift` | Add socket polling, remove string matching for state |

---

## Part 2: Dry-Run Mode

### Problem

Can't test the app end-to-end without real GitHub credentials and a tart
VM host. Need the Go binary to simulate the full lifecycle.

### Solution

`--dry-run` flag swaps real backends for mocks. The mock backends:
- Log the same messages as real mode
- Simulate timing (boot delays, job duration)
- Respond to IPC the same way
- Cycle through fake jobs on a timer

### Go Side

**New file: `mock.go`**

```go
// MockTartOperations simulates tart commands with logging + delays.
type MockTartOperations struct { logger *slog.Logger }
func (m *MockTartOperations) Clone(...) error { sleep 100ms; log; return nil }
func (m *MockTartOperations) Run(...) error { sleep 30s; log; return nil }
// etc.

// MockScalesetClient simulates the GitHub scaleset API.
type MockScalesetClient struct { ... }
// Returns fake scale set IDs, generates fake JIT configs,
// simulates job events on a timer.
```

**Integration:**
- `--dry-run` flag in `main.go`
- In `run()`: if dry-run, use `MockTartOperations` instead of real tart,
  and `MockScalesetClient` instead of real scaleset client
- The listener is replaced with a mock that periodically calls
  `HandleDesiredRunnerCount`, `HandleJobStarted`, `HandleJobCompleted`
- Control socket works identically — same AppStatus, same endpoints

### Files Changed

| File | Change |
|------|--------|
| `mock.go` | **New** — MockTartOperations, mock scaleset/listener |
| `main.go` | Add `--dry-run` flag |
| `run.go` | Branch on dry-run to use mocks |

---

## Part 3: UI Testing

### Approach

Two layers:

1. **RunnerManager unit tests** — test state machine logic with mocked Process
2. **XCTest UI tests** — launch the real app in dry-run mode, verify menu bar

### Unit Tests

Add a test target to `ConfigUI/Package.swift`:

```swift
.testTarget(
    name: "GrafteryTests",
    dependencies: ["Graftery"],
    path: "Tests"
)
```

Test cases:
- `RunnerManager` state transitions (idle → starting → running → stopping → idle)
- `RunnerStore` migration logic
- `RunnerStore` config loading/saving
- `LogStore` parsing
- `ScriptLoader` merge logic (already have these in provisioner/)

### XCTest UI Tests

Add a UI test target. The test:
1. Launches the app with `--dry-run` injected into the Go binary args
2. Waits for the menu bar item to appear
3. Clicks the menu bar item
4. Asserts the menu shows "Running" (not "Starting")
5. Clicks "Stop" and asserts "Idle"

```swift
class GrafteryUITests: XCTestCase {
    func testMenuBarShowsRunningState() {
        let app = XCUIApplication()
        app.launchArguments = ["--dry-run"]
        app.launch()
        
        let menuBarItem = app.menuBarItems["Graftery"]
        XCTAssert(menuBarItem.waitForExistence(timeout: 5))
        menuBarItem.click()
        
        // Wait for state to transition to Running
        let runningText = app.menuItems.staticTexts["Running"]
        XCTAssert(runningText.waitForExistence(timeout: 15))
    }
}
```

### Files Changed

| File | Change |
|------|--------|
| `ConfigUI/Package.swift` | Add test targets |
| `ConfigUI/Tests/RunnerManagerTests.swift` | **New** — unit tests |
| `ConfigUI/Tests/RunnerStoreTests.swift` | **New** — unit tests |
| `ConfigUI/UITests/MenuBarTests.swift` | **New** — XCTest UI tests |

---

## Implementation Order

1. **Control socket IPC** (Part 1) — fixes the immediate state detection bug
   and establishes the communication foundation
2. **Dry-run mode** (Part 2) — enables testing without real infrastructure
3. **UI tests** (Part 3) — uses dry-run mode to verify app behavior

Part 1 is the priority. Parts 2 and 3 build on it.
