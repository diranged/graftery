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

/// Persistent state for runner configurations. Tracks which configs exist
/// and whether each is enabled for auto-start. Stored as JSON at
/// `~/Library/Application Support/graftery/runner-state.json`.
///
/// This file is separate from the YAML configs because the Go CLI doesn't
/// need the enabled/disabled state — it's purely a UI concern.
struct RunnerStateFile: Codable {
    /// All known configurations and their enabled state.
    var configs: [RunnerConfigEntry]
}

/// A single entry in the runner state file. Maps a config name to its
/// enabled/disabled flag. The `name` field matches the YAML filename stem.
struct RunnerConfigEntry: Codable, Identifiable {
    var id: String { name }
    var name: String
    var enabled: Bool = true
}

/// Manages the collection of named runner configurations.
///
/// Each config gets its own `RunnerManager` (Go subprocess) and `LogStore`.
/// The store handles:
/// - **Scanning** the `configs/` directory on startup to discover YAML files
/// - **Migrating** from the legacy single-config layout (pre-multi-config)
/// - **Creating, deleting, and toggling** configurations
/// - **Auto-starting** enabled configs on launch
/// - **Persisting** the enabled/disabled state to `runner-state.json`
///
/// The store publishes changes via `@Published` properties and also manually
/// calls `objectWillChange.send()` when child `RunnerManager` state changes,
/// so SwiftUI views (menu bar, sidebar) re-render on runner state transitions.
@MainActor
class RunnerStore: ObservableObject {
    @Published var instances: [RunnerInstance] = []
    @Published var selectedConfigName: String? = nil
    /// Set to true when no configs exist — triggers the setup wizard.
    @Published var needsFirstRunWizard: Bool = false
    /// True if tart cannot be found anywhere — blocks all configs from starting.
    @Published var tartMissing: Bool = false
    /// The resolved absolute path to the tart binary (if found).
    @Published var resolvedTartPath: String = ""

    /// Guard against double-loading if init delay races with explicit call.
    private var didLoad = false

    init() {
        // Delay loading to let SwiftUI finish setting up its scene graph.
        // Without this delay, opening windows from loadAll() can race with
        // SwiftUI's own window creation during app launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.loadAll()
        }
    }

    /// Scans the configs directory, runs migration if needed, creates a
    /// `RunnerInstance` for each config, and auto-starts enabled ones.
    ///
    /// Migration logic: if `configs/` doesn't exist but the legacy
    /// `config.yaml` does (from the single-config era), it is moved
    /// into `configs/default.yaml` and the original is renamed to
    /// `config.yaml.migrated` as a backup.
    func loadAll() {
        guard !didLoad else { return }
        didLoad = true

        let fm = FileManager.default

        // Migration: convert legacy single-config layout to multi-config.
        if !fm.fileExists(atPath: AppConfig.configsDir) {
            try? fm.createDirectory(atPath: AppConfig.configsDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: AppConfig.defaultPath),
               let cfg = try? AppConfig.load(from: AppConfig.defaultPath),
               !cfg.url.isEmpty, !cfg.name.isEmpty {
                let destPath = AppConfig.configPath(forName: AppConstants.defaultConfigName)
                try? fm.copyItem(atPath: AppConfig.defaultPath, toPath: destPath)
                try? fm.moveItem(
                    atPath: AppConfig.defaultPath,
                    toPath: AppConfig.defaultPath + AppConstants.migratedFileSuffix
                )
                let state = RunnerStateFile(configs: [
                    RunnerConfigEntry(name: AppConstants.defaultConfigName, enabled: true)
                ])
                saveStateFile(state)
            } else {
                // No legacy config found — this is a first-time install.
                needsFirstRunWizard = true
                return
            }
        }

        // Load the state file (tracks which configs are enabled).
        var state = loadStateFile()

        // Discover YAML files in the configs directory.
        let yamlFiles = (try? fm.contentsOfDirectory(atPath: AppConfig.configsDir))?
            .filter { $0.hasSuffix(AppConstants.configFileExtension) }
            .map { String($0.dropLast(AppConstants.configFileExtension.count)) }
            ?? []

        // Reconcile: add any YAML files not yet in the state file.
        let knownNames = Set(state.configs.map(\.name))
        for name in yamlFiles where !knownNames.contains(name) {
            state.configs.append(RunnerConfigEntry(name: name, enabled: true))
        }

        // Reconcile: remove state entries for YAML files that no longer exist.
        let existingNames = Set(yamlFiles)
        state.configs.removeAll { !existingNames.contains($0.name) }
        saveStateFile(state)

        // Create RunnerInstance for each config. Wire up the onStateChange
        // callback so RunnerStore publishes changes when any runner's state
        // changes — this makes SwiftUI re-render the menu bar content and
        // the configurations sidebar automatically.
        instances = state.configs.map { [weak self] entry in
            let instance = RunnerInstance(
                name: entry.name,
                configPath: AppConfig.configPath(forName: entry.name),
                enabled: entry.enabled
            )
            instance.manager.onStateChange = {
                self?.objectWillChange.send()
            }
            return instance
        }

        if instances.isEmpty {
            needsFirstRunWizard = true
            return
        }

        // Check for tart before auto-starting any runners.
        checkTartAvailable()
        if !tartMissing {
            startAllEnabled()
        }
    }

    /// Creates a new configuration with the given name and default values.
    /// The new config is immediately added to the instances list and
    /// persisted to the state file.
    ///
    /// - Parameter name: The configuration name (used as filename stem).
    func addConfig(name: String) {
        let path = AppConfig.configPath(forName: name)
        let cfg = AppConfig()
        try? cfg.save(to: path)

        let instance = RunnerInstance(name: name, configPath: path, enabled: true)
        instance.manager.onStateChange = { [weak self] in
            self?.objectWillChange.send()
        }
        instances.append(instance)
        saveState()
    }

    /// Stops the runner, deletes the config YAML file, and removes the
    /// instance from the store. The state file is updated to reflect
    /// the removal.
    ///
    /// - Parameter name: The configuration name to remove.
    func removeConfig(name: String) async {
        if let instance = instance(named: name) {
            await instance.manager.stopAndWait()
        }
        instances.removeAll { $0.name == name }

        let path = AppConfig.configPath(forName: name)
        try? FileManager.default.removeItem(atPath: path)
        saveState()
    }

    /// Toggles the enabled flag for a config. When enabled, the runner is
    /// started immediately. When disabled, the runner is stopped and won't
    /// auto-start on next app launch.
    ///
    /// - Parameter name: The configuration name to toggle.
    func toggleEnabled(name: String) {
        guard let instance = instance(named: name) else { return }
        instance.enabled.toggle()
        if instance.enabled {
            instance.manager.start()
        } else {
            instance.manager.stop()
        }
        saveState()
    }

    /// Starts all runner instances that have `enabled == true`.
    /// Called after initial load and after tart is (re)discovered.
    func startAllEnabled() {
        for instance in instances where instance.enabled {
            instance.manager.start()
        }
    }

    /// Stops all running runner instances, regardless of enabled state.
    /// Used by the "Stop All" menu item and before app quit.
    func stopAll() async {
        for instance in instances {
            await instance.manager.stopAndWait()
        }
    }

    /// Looks up a runner instance by its configuration name.
    ///
    /// - Parameter name: The configuration name to find.
    /// - Returns: The matching `RunnerInstance`, or nil if not found.
    func instance(named name: String) -> RunnerInstance? {
        instances.first { $0.name == name }
    }

    /// The currently selected instance, derived from `selectedConfigName`.
    /// Used by the detail pane in `ConfigurationsView`.
    var selectedInstance: RunnerInstance? {
        guard let name = selectedConfigName else { return nil }
        return instance(named: name)
    }

    /// Persists the current instances' names and enabled flags to the
    /// runner state JSON file.
    func saveState() {
        let entries = instances.map { RunnerConfigEntry(name: $0.name, enabled: $0.enabled) }
        saveStateFile(RunnerStateFile(configs: entries))
    }

    // MARK: - Tart Detection

    /// Common filesystem locations where tart might be installed.
    /// Checked when PATH doesn't contain tart (common for GUI apps launched
    /// via launchd, which get a minimal PATH).
    private static let commonTartPaths = [
        "/opt/homebrew/bin/tart",
        "/usr/local/bin/tart",
        "/run/current-system/sw/bin/tart",
        "/nix/var/nix/profiles/default/bin/tart",
        NSHomeDirectory() + "/.nix-profile/bin/tart",
        "/opt/local/bin/tart",
    ]

    /// Searches for the tart binary in config files, PATH, and common locations.
    /// Updates `tartMissing` and `resolvedTartPath` based on the result.
    ///
    /// - Returns: `true` if tart was found, `false` otherwise.
    @discardableResult
    func checkTartAvailable() -> Bool {
        let fm = FileManager.default

        // Check any existing config's tart_path field (user may have set it).
        for instance in instances {
            if let cfg = try? AppConfig.load(from: instance.configPath),
               !cfg.tartPath.isEmpty,
               fm.isExecutableFile(atPath: cfg.tartPath) {
                resolvedTartPath = cfg.tartPath
                tartMissing = false
                return true
            }
        }

        // Scan PATH directories.
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(AppConstants.tartBinaryName)
            if fm.isExecutableFile(atPath: candidate) {
                saveTartPathToAllConfigs(candidate)
                return true
            }
        }

        // Check well-known install locations (Homebrew, Nix, MacPorts).
        for candidate in Self.commonTartPaths {
            if fm.isExecutableFile(atPath: candidate) {
                saveTartPathToAllConfigs(candidate)
                return true
            }
        }

        tartMissing = true
        return false
    }

    /// Saves the resolved tart path to all existing config YAML files.
    /// This ensures every Go CLI subprocess can find tart regardless of
    /// the minimal PATH that launchd provides to GUI apps.
    ///
    /// - Parameter path: The absolute path to the tart binary.
    func saveTartPathToAllConfigs(_ path: String) {
        resolvedTartPath = path
        tartMissing = false
        for instance in instances {
            if var cfg = try? AppConfig.load(from: instance.configPath) {
                cfg.tartPath = path
                try? cfg.save(to: instance.configPath)
            }
        }
    }

    // MARK: - State File I/O

    /// Loads the runner state JSON file from disk.
    /// Returns an empty state if the file doesn't exist or can't be decoded.
    private func loadStateFile() -> RunnerStateFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: AppConfig.runnerStatePath)),
              let state = try? JSONDecoder().decode(RunnerStateFile.self, from: data) else {
            return RunnerStateFile(configs: [])
        }
        return state
    }

    /// Writes the runner state to the JSON file, creating the parent
    /// directory if needed.
    private func saveStateFile(_ state: RunnerStateFile) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let dir = (AppConfig.runnerStatePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: AppConfig.runnerStatePath))
    }
}

/// Represents a single runner configuration with its subprocess manager
/// and log buffer.
///
/// Each instance is identified by `name`, which matches the YAML filename
/// stem in the `configs/` directory (e.g., "my-runner" -> "my-runner.yaml").
/// The instance owns a `RunnerManager` for subprocess lifecycle and a
/// `LogStore` for real-time log display.
@MainActor
class RunnerInstance: Identifiable, ObservableObject {
    let id: String
    /// The configuration name — matches the YAML filename stem.
    let name: String
    /// Absolute path to the YAML config file on disk.
    let configPath: String
    /// Manages the Go CLI subprocess lifecycle for this configuration.
    let manager: RunnerManager
    /// Per-instance log buffer fed by the CLI subprocess pipe.
    let logStore: LogStore
    /// Whether this config auto-starts on app launch and is shown as active.
    @Published var enabled: Bool

    init(name: String, configPath: String, enabled: Bool = true) {
        self.id = name
        self.name = name
        self.configPath = configPath
        self.enabled = enabled
        self.manager = RunnerManager(configPath: configPath, configName: name)
        self.logStore = manager.logStore
    }
}
