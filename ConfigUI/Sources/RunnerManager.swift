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

import Foundation

/// Manages a single Go CLI binary (`graftery-cli`) subprocess for one
/// runner configuration. Each configuration gets its own `RunnerManager` instance
/// with its own config path, log store, and subprocess lifecycle.
///
/// In multi-config mode, `RunnerStore` creates and manages `RunnerManager`
/// instances — startup and shutdown are controlled by the store, not by
/// `RunnerManager` itself. This class is purely responsible for the subprocess
/// lifecycle: launching, monitoring (via control socket), and terminating.
@MainActor
class RunnerManager: ObservableObject {
    /// Lifecycle state of the managed CLI subprocess.
    ///
    /// State transitions:
    /// - idle -> starting -> running -> stopping -> idle (normal lifecycle)
    /// - idle -> starting -> error (failed to reach running state)
    /// - running -> error (unexpected subprocess exit)
    /// - error -> starting (user retries)
    enum State: String {
        case idle = "Idle"
        case starting = "Starting"
        case running = "Running"
        case stopping = "Stopping"
        case error = "Error"
    }

    @Published var state: State = .idle {
        didSet {
            // Notify RunnerStore so it can forward objectWillChange to SwiftUI,
            // which triggers re-render of menu bar content and config sidebar.
            onStateChange?()
        }
    }

    /// Callback invoked when state changes. Set by `RunnerStore` to trigger
    /// `objectWillChange` on the store, which makes SwiftUI re-render the
    /// menu bar content and configurations sidebar. Using a closure here
    /// (rather than Combine) keeps RunnerManager decoupled from RunnerStore.
    var onStateChange: (() -> Void)?

    /// The most recent error message, shown in the UI. Populated from CLI
    /// output on unexpected exit, or from pre-flight checks (tart missing, etc).
    @Published var lastError: String?

    /// Set to true when tart is not found on the system. The UI uses this
    /// to show a prominent warning and block the runner from starting.
    @Published var tartMissing = false

    /// Combined CPU usage percentage across all running VMs for this config.
    /// Updated every poll cycle from the control socket /status response.
    @Published var runnerCPUPercent: Double = 0

    /// Combined memory (RSS) in bytes across all running VMs for this config.
    /// Updated every poll cycle from the control socket /status response.
    @Published var runnerMemoryBytes: UInt64 = 0

    /// Host total memory in bytes, used to scale memory bars to 0-100%.
    @Published var hostMemoryTotal: UInt64 = 0

    /// Host CPU core count, used to normalize per-process CPU percentages
    /// (gopsutil reports per-core, e.g., 300% = 3 cores) to 0-100% of host.
    @Published var hostCPUCount: Int = 1

    /// Rolling history of metrics data points for the time-series graph.
    /// Each entry is a snapshot of CPU and memory at a point in time.
    @Published var metricsHistory: [MetricsDataPoint] = []

    /// Maximum number of data points to keep in the history buffer.
    /// At 2-second polling, 900 points = 30 minutes of history.
    static let maxHistoryPoints = 900

    /// The YAML config file path for this runner instance.
    let configPath: String

    /// Display name for this configuration (matches the YAML filename stem).
    let configName: String

    /// Per-instance log buffer. Each runner has its own log store so logs
    /// from different configurations don't intermingle in the log viewer.
    let logStore: LogStore

    /// Control socket client for polling the Go CLI's structured HTTP/JSON API.
    private var controlClient: ControlSocketClient?

    /// Timer that polls the control socket for state updates. Runs in `.common`
    /// mode so it fires even when NSMenu is open (event tracking mode).
    private var pollTimer: Timer?

    /// Path to the Unix domain socket file for this runner instance.
    /// The Go CLI creates this socket on startup and removes it on shutdown.
    private var controlSocketPath: String {
        "\(AppConstants.controlSocketPrefix)\(configName)\(AppConstants.controlSocketSuffix)"
    }

    init(configPath: String, configName: String) {
        self.configPath = configPath
        self.configName = configName
        self.logStore = LogStore()
    }

    /// The running Process instance, if any. Nil when idle or after termination.
    private var process: Process?

    /// Pipe capturing both stdout and stderr from the CLI subprocess.
    private var outputPipe: Pipe?

    /// Holds the last few lines of CLI output so we can surface a meaningful
    /// error message if the process exits unexpectedly. Without this, the user
    /// would only see "Process exited with code N" which is not actionable.
    private var recentOutput: [String] = []

    /// Locates the Go CLI binary. Checks two locations in order:
    /// 1. Inside the app bundle at `Contents/Resources/` (production .app builds)
    /// 2. Next to the main executable (development/debug builds from Xcode)
    ///
    /// Returns nil if the binary cannot be found in either location.
    private var cliBinaryPath: String? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent(AppConstants.cliBinaryName)
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        if let execPath = Bundle.main.executablePath {
            let dir = (execPath as NSString).deletingLastPathComponent
            let beside = (dir as NSString).appendingPathComponent(AppConstants.cliBinaryName)
            if FileManager.default.fileExists(atPath: beside) {
                return beside
            }
        }

        return nil
    }

    /// Common filesystem locations where tart might be installed on macOS.
    /// Checked when PATH doesn't contain tart — which is common for GUI apps
    /// because launchd gives them a minimal PATH that typically only includes
    /// `/usr/bin:/bin:/usr/sbin:/sbin`.
    private static let commonTartPaths = [
        "/opt/homebrew/bin/tart",
        "/usr/local/bin/tart",
        "/run/current-system/sw/bin/tart",
        "/nix/var/nix/profiles/default/bin/tart",
        NSHomeDirectory() + "/.nix-profile/bin/tart",
        "/opt/local/bin/tart",
    ]

    /// The resolved absolute path to the tart binary. Set by `checkTartAvailable()`
    /// when tart is found, and persisted to the config so the Go CLI (which also
    /// gets a minimal PATH) can use it directly.
    @Published var resolvedTartPath: String = ""

    /// Searches for the tart binary in multiple locations. Search order:
    /// 1. The config file's explicit `tart_path` field (user override)
    /// 2. PATH directories from the current environment
    /// 3. Common install locations (Homebrew, Nix, MacPorts)
    ///
    /// If found, the resolved path is saved back to the config's `tart_path` field
    /// so the Go binary (which gets a minimal PATH from launchd) can find it.
    ///
    /// - Returns: `true` if tart was found, `false` otherwise.
    @discardableResult
    func checkTartAvailable() -> Bool {
        let fm = FileManager.default

        // 1. Check the config's explicit tart_path (user may have set it manually).
        if let cfg = try? AppConfig.load(from: configPath),
           !cfg.tartPath.isEmpty,
           fm.isExecutableFile(atPath: cfg.tartPath) {
            resolvedTartPath = cfg.tartPath
            tartMissing = false
            return true
        }

        // 2. Scan PATH directories for a "tart" executable.
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(AppConstants.tartBinaryName)
            if fm.isExecutableFile(atPath: candidate) {
                saveTartPath(candidate)
                return true
            }
        }

        // 3. Check well-known install locations (Homebrew, Nix, MacPorts).
        for candidate in Self.commonTartPaths {
            if fm.isExecutableFile(atPath: candidate) {
                saveTartPath(candidate)
                return true
            }
        }

        tartMissing = true
        state = .error
        lastError = "Tart not found. Use 'Locate Tart...' to select the tart binary, or install it:\n\nbrew install cirruslabs/cli/tart"
        return false
    }

    /// Persists the discovered tart path to the config YAML file so the Go
    /// CLI subprocess can use it. GUI apps launched via launchd get a minimal
    /// PATH, so the Go binary needs the absolute path written into its config.
    func saveTartPath(_ path: String) {
        resolvedTartPath = path
        tartMissing = false

        if var cfg = try? AppConfig.load(from: configPath) {
            cfg.tartPath = path
            try? cfg.save(to: configPath)
        }
    }

    /// Launches the CLI subprocess with the current config file.
    ///
    /// Pre-flight checks (in order):
    /// 1. State must be `.idle` or `.error` (prevents double-start)
    /// 2. Tart must be available (checked via `checkTartAvailable()`)
    /// 3. The CLI binary must be found in the app bundle
    /// 4. The config file must exist on disk
    ///
    /// Once launched, stdout/stderr are piped to `LogStore` for display,
    /// and the control socket is polled for structured state updates.
    func start() {
        guard state == .idle || state == .error else { return }

        guard checkTartAvailable() else { return }

        guard let binary = cliBinaryPath else {
            state = .error
            lastError = "Could not locate \(AppConstants.cliBinaryName) binary"
            return
        }

        let configPath = self.configPath
        guard FileManager.default.fileExists(atPath: configPath) else {
            state = .error
            lastError = "Config file not found at \(configPath)"
            return
        }

        state = .starting
        lastError = nil
        recentOutput = []

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--config", configPath, "--control-socket", controlSocketPath]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        // Forward CLI output to LogStore for display in the log viewer.
        // State detection is handled by the control socket poller (not by
        // parsing pipe output), which is more reliable than string matching.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                self.logStore.append(rawOutput: str)

                // Keep recent output lines for error reporting on unexpected exit.
                let newLines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                self.recentOutput.append(contentsOf: newLines)
                if self.recentOutput.count > AppConstants.recentOutputLimit {
                    self.recentOutput = Array(self.recentOutput.suffix(AppConstants.recentOutputLimit))
                }
            }
        }

        // Handle process exit. If we initiated the stop (state == .stopping),
        // transition to idle. Otherwise, it's an unexpected exit — surface the
        // recent output as an error message so the user can diagnose the issue.
        proc.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.process = nil
                self.stopPolling()

                if self.state == .stopping {
                    self.state = .idle
                } else if proc.terminationStatus != 0 {
                    self.state = .error
                    let detail = self.recentOutput.joined(separator: "\n")
                    if detail.isEmpty {
                        self.lastError = "Process exited with code \(proc.terminationStatus)"
                    } else {
                        self.lastError = detail
                    }
                } else {
                    self.state = .idle
                }
            }
        }

        do {
            try proc.run()
            process = proc
            startPolling()
        } catch {
            state = .error
            lastError = "Failed to start: \(error.localizedDescription)"
        }
    }

    // MARK: - Control Socket Polling

    /// Starts a timer that polls the Go CLI's control socket every 2 seconds.
    /// The control socket exposes an HTTP/JSON API on a Unix domain socket,
    /// providing reliable structured state information. This is preferred over
    /// parsing pipe output because:
    /// 1. Structured JSON is unambiguous (no false positives from log messages)
    /// 2. The Go CLI may buffer stdout, causing delays in pipe-based detection
    /// 3. The control socket provides additional data (runner counts, health)
    private func startPolling() {
        controlClient = ControlSocketClient(socketPath: controlSocketPath)
        // Timer must run in `.common` mode so it fires even when NSMenu is open,
        // which puts the run loop into event-tracking mode. Without `.common`,
        // state updates would freeze while the user has the menu open.
        // `MainActor.assumeIsolated` is safe here because Timer on the main
        // RunLoop always fires on the main thread.
        let timer = Timer(timeInterval: AppConstants.controlSocketPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollControlSocket()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stops the control socket polling timer and releases the client.
    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        controlClient = nil
    }

    /// Reads the latest status from the control socket and maps the Go CLI's
    /// state string to our Swift `State` enum. Only transitions state forward
    /// (e.g., starting -> running) to avoid race conditions where a stale poll
    /// response could revert a user-initiated state change.
    private func pollControlSocket() {
        guard let client = controlClient else { return }
        guard let status = client.getStatus() else { return }

        // Map Go state strings (defined in the Go CLI's status.go) to Swift State.
        // These string values must stay in sync with the Go codebase.
        switch status.state {
        case AppConstants.CLIState.running:
            if state == .starting {
                state = .running
            }
        case AppConstants.CLIState.error:
            state = .error
            lastError = status.error
        case AppConstants.CLIState.stopping:
            if state != .stopping {
                state = .stopping
            }
        case AppConstants.CLIState.idle:
            if state == .starting || state == .running {
                state = .idle
            }
        default:
            break
        }

        // Aggregate per-runner CPU and memory across all runners for this config.
        var totalCPU: Double = 0
        var totalMem: UInt64 = 0
        for runner in status.runners {
            totalCPU += runner.cpuPercent ?? 0
            totalMem += runner.memoryRss ?? 0
        }
        runnerCPUPercent = totalCPU
        runnerMemoryBytes = totalMem
        if let host = status.host {
            hostMemoryTotal = host.memoryTotal
            hostCPUCount = max(host.cpuCount, 1)
        }

        // Append to metrics history for the time-series graph.
        let cpuNorm = Double(max(hostCPUCount, 1))
        let memTotal = Double(max(hostMemoryTotal, 1))
        let point = MetricsDataPoint(
            timestamp: Date(),
            cpuPercent: totalCPU / cpuNorm,
            memoryPercent: Double(totalMem) / memTotal * 100
        )
        metricsHistory.append(point)
        if metricsHistory.count > Self.maxHistoryPoints {
            metricsHistory.removeFirst(metricsHistory.count - Self.maxHistoryPoints)
        }
    }

    /// Sends SIGINT to the CLI process, triggering its graceful shutdown path.
    /// The Go CLI catches SIGINT to drain active jobs, deregister runners,
    /// and clean up VMs before exiting.
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        state = .stopping
        proc.interrupt() // SIGINT — triggers graceful shutdown in the Go CLI
    }

    /// Sends SIGINT and blocks the calling async context until the CLI process
    /// exits. Used by quit and reset flows that need to guarantee the process
    /// is fully stopped before proceeding (e.g., before NSApp.terminate).
    func stopAndWait() async {
        guard let proc = process, proc.isRunning else { return }
        state = .stopping
        proc.interrupt()
        proc.waitUntilExit()
    }

    /// Restarts the CLI subprocess with fresh config. Called by the config editor
    /// after autosave when the runner is currently active, so config changes
    /// take effect immediately without manual stop/start.
    func restart() async {
        if process?.isRunning == true {
            await stopAndWait()
        }
        start()
    }

    /// Short text shown next to the menu bar icon. Empty when idle/running
    /// (the icon alone is sufficient); "..." during transitions to indicate
    /// activity; "ERR" on failure to draw attention.
    var menuBarTitle: String {
        switch state {
        case .idle: return ""
        case .starting: return "..."
        case .running: return ""
        case .stopping: return "..."
        case .error: return "ERR"
        }
    }
}
