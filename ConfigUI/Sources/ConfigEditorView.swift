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

import SwiftUI
import UniformTypeIdentifiers

/// Tabs for the macOS System Preferences-style configuration window.
/// Each case corresponds to a section of the config editor. The `.logs` tab
/// is special — it embeds the `LogViewerView` instead of config fields.
enum ConfigTab: String, CaseIterable, Identifiable {
    case general = "General"
    case auth = "Authentication"
    case runners = "Runners"
    case provisioning = "Provisioning"
    case logging = "Logging"
    case logs = "Logs"

    var id: String { rawValue }

    /// SF Symbol name for the tab icon shown in the tab bar.
    /// These are centralized in `AppConstants.SFSymbol.Tab` to prevent
    /// typos (invalid SF Symbol names compile but render as empty images).
    var icon: String {
        switch self {
        case .general: return AppConstants.SFSymbol.Tab.general
        case .auth: return AppConstants.SFSymbol.Tab.auth
        case .runners: return AppConstants.SFSymbol.Tab.runners
        case .provisioning: return AppConstants.SFSymbol.Tab.provisioning
        case .logging: return AppConstants.SFSymbol.Tab.logging
        case .logs: return AppConstants.SFSymbol.Tab.logs
        }
    }
}

/// Tabbed configuration editor styled like macOS System Preferences.
///
/// Changes are **auto-saved** to the YAML config file whenever any field changes.
/// If the runner is currently active, it is automatically restarted with the new
/// config so changes take effect immediately.
///
/// The editor loads config from disk on appear and suppresses autosave during
/// the initial load (via `isLoading`) to avoid a save-on-load feedback loop.
struct ConfigEditorView: View {
    @ObservedObject var runner: RunnerManager
    @EnvironmentObject var logStore: LogStore
    @State private var config = AppConfig()
    @State private var selectedTab: ConfigTab = .general
    /// Tracks which auth method section to show (GitHub App vs PAT).
    @State private var useGitHubApp = true
    /// Tracks whether the private key source is a file path or pasted content.
    @State private var useKeyFile = false
    @State private var showSaveSuccess = false
    @State private var errorMessage: String?
    /// Suppresses autosave during initial config load to prevent a
    /// save-triggered-by-load feedback loop.
    @State private var isLoading = true
    @State private var showFileImporter = false
    @State private var showDirImporter = false
    @State private var hasUnsavedChanges = false

    private var configPath: String { runner.configPath }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — classic macOS preferences style with icon + label
            HStack(spacing: 0) {
                ForEach(ConfigTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                            Text(tab.rawValue)
                                .font(.caption)
                        }
                        .frame(width: 80, height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Tab content — each tab is a Form with grouped style
            Group {
                switch selectedTab {
                case .general: generalTab
                case .auth: authTab
                case .runners: runnersTab
                case .provisioning: provisioningTab
                case .logging: loggingTab
                case .logs: logsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: loadConfig)
        // Auto-save on any config field change, but skip during initial load.
        .onChange(of: config) {
            guard !isLoading else { return }
            hasUnsavedChanges = true
            autosave()
        }
        .onChange(of: useGitHubApp) {
            guard !isLoading else { return }
            hasUnsavedChanges = true
            autosave()
        }
        .onChange(of: useKeyFile) {
            guard !isLoading else { return }
            hasUnsavedChanges = true
            autosave()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                config.appPrivateKeyPath = url.path
            }
        }
    }

    // MARK: - Tabs

    /// General tab: GitHub connection URL and runner identity settings.
    private var generalTab: some View {
        Form {
            Section {
                TextField("Registration URL", text: $config.url, prompt: Text("https://github.com/my-org"))
                fieldHint("The GitHub org or repo URL for scale set registration.")
            } header: {
                Text("GitHub Connection")
            }

            Section {
                TextField("Scale Set Name", text: $config.name, prompt: Text("my-macos-runner"))
                fieldHint("Also used as the runs-on label in workflows.")

                TextField("Labels", text: $config.labelsString, prompt: Text("self-hosted, macOS, ARM64"))
                fieldHint("Comma-separated. Leave blank to use the name as the sole label.")

                TextField("Runner Group", text: $config.runnerGroup, prompt: Text("default"))

                TextField("Runner Prefix", text: $config.runnerPrefix, prompt: Text("runner"))
                fieldHint("VM name prefix, also used for orphan detection on startup.")
            } header: {
                Text("Runner Identity")
            }

            saveStatus
        }
        .formStyle(.grouped)
    }

    /// Auth tab: choose between GitHub App and PAT, then fill in credentials.
    /// The editor strips credentials for the unselected method on save to
    /// prevent stale credentials from leaking into the config file.
    private var authTab: some View {
        Form {
            Section {
                Picker("Authentication Method", selection: $useGitHubApp) {
                    Text("GitHub App (recommended)").tag(true)
                    Text("Personal Access Token").tag(false)
                }
                .pickerStyle(.segmented)
            }

            if useGitHubApp {
                Section {
                    TextField("Client ID", text: $config.appClientID, prompt: Text("Iv1.abc123..."))
                    TextField("Installation ID", text: $config.installationIDString, prompt: Text("12345678"))

                    Picker("Private Key Source", selection: $useKeyFile) {
                        Text("Paste Key Contents").tag(false)
                        Text("Key File Path").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if useKeyFile {
                        HStack {
                            TextField("Path", text: $config.appPrivateKeyPath, prompt: Text("/path/to/private-key.pem"))
                            Button("Browse...") {
                                showFileImporter = true
                            }
                        }
                    } else {
                        TextEditor(text: $config.appPrivateKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100, maxHeight: 180)
                            .border(Color(nsColor: .separatorColor))
                        fieldHint("Paste the full PEM private key contents.")
                    }

                    Link("How to create a GitHub App \u{2192}",
                         destination: URL(string: AppConstants.gitHubAppDocsURL)!)
                        .font(.callout)
                } header: {
                    Text("GitHub App Credentials")
                }
            } else {
                Section {
                    SecureField("Token", text: $config.token, prompt: Text("ghp_xxxx..."))
                    fieldHint("A classic or fine-grained PAT with appropriate permissions.")
                } header: {
                    Text("Personal Access Token")
                }
            }

            saveStatus
        }
        .formStyle(.grouped)
    }

    /// Runners tab: Tart VM image and concurrency (min/max runner) settings.
    /// Apple Silicon currently allows a maximum of 2 concurrent macOS VMs,
    /// but the stepper goes up to 10 for future hardware flexibility.
    private var runnersTab: some View {
        Form {
            Section {
                TextField("Base Image", text: $config.baseImage, prompt: Text("ghcr.io/cirruslabs/macos-runner:sonoma"))
                fieldHint("The Tart VM image to clone for each runner.")
            } header: {
                Text("VM Image")
            }

            Section {
                Stepper("Maximum Runners: \(config.maxRunners)", value: $config.maxRunners, in: 1...10)
                fieldHint("Apple Silicon allows a maximum of 2 concurrent macOS VMs.")

                Stepper("Minimum Runners: \(config.minRunners)", value: $config.minRunners, in: 0...config.maxRunners)
                fieldHint("Warm pool \u{2014} VMs kept running to reduce job start latency.")
            } header: {
                Text("Concurrency")
            }

            saveStatus
        }
        .formStyle(.grouped)
    }

    /// Provisioning tab: image baking scripts, hooks, and tart binary location.
    /// The scripts directory structure (`bake.d/`, `hooks/pre.d/`, `hooks/post.d/`)
    /// is created automatically when the user clicks "Open in Finder".
    private var provisioningTab: some View {
        Form {
            Section {
                TextField("Tart Binary Path", text: $config.tartPath, prompt: Text("(auto-detect from PATH)"))
                fieldHint("Leave blank to find tart in PATH automatically. Set this if tart is installed in a non-standard location.")
            } header: {
                Text("Tart Binary")
            }

            Section {
                HStack {
                    TextField("Scripts Directory", text: $config.provisioning.scriptsDir,
                              prompt: Text(AppConfig.defaultScriptsDir))
                    Button("Browse...") {
                        showDirImporter = true
                    }
                    Button("Open in Finder") {
                        let dir = config.provisioning.scriptsDir.isEmpty
                            ? AppConfig.defaultScriptsDir
                            : config.provisioning.scriptsDir
                        // Create the expected subdirectory structure if it doesn't exist,
                        // so the user sees the layout immediately in Finder.
                        let fm = FileManager.default
                        for subdir in AppConstants.provisioningSubdirs {
                            try? fm.createDirectory(
                                atPath: (dir as NSString).appendingPathComponent(subdir),
                                withIntermediateDirectories: true,
                                attributes: nil
                            )
                        }
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                    }
                }
                fieldHint("Directory containing custom bake.d/ and hooks/ scripts. User scripts merge with built-in defaults.")

                TextField("Prepared Image Name", text: $config.provisioning.preparedImageName,
                          prompt: Text("(auto-generated from base image)"))
                fieldHint("Override the local tart VM name used for the baked image. Leave blank for auto-generated.")

                Toggle("Skip Built-in Scripts", isOn: $config.provisioning.skipBuiltinScripts)
                fieldHint("When enabled, only your custom scripts run. Disable the embedded startup script, hooks, and setup info.")
            } header: {
                Text("Image Provisioning")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom scripts are merged with built-in defaults:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Group {
                        Text("bake.d/")
                            .fontWeight(.medium) +
                        Text(" \u{2014} Scripts run during image baking (01-foo.sh, 50-bar.sh)")
                        Text("hooks/pre.d/")
                            .fontWeight(.medium) +
                        Text(" \u{2014} Run before each job (visible in 'Set up runner')")
                        Text("hooks/post.d/")
                            .fontWeight(.medium) +
                        Text(" \u{2014} Run after each job (visible in 'Complete runner')")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Text("Scripts with the same name as built-ins override them. Use --reprovision to rebuild after changes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Script Directory Layout")
            }

            saveStatus
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showDirImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                config.provisioning.scriptsDir = url.path
            }
        }
    }

    /// Logging tab: log level/format picker and read-only log destination info.
    /// Log files are written by the Go CLI (not by this app), so the paths
    /// shown here are informational only.
    private var loggingTab: some View {
        Form {
            Section {
                Picker("Log Level", selection: $config.logLevel) {
                    Text("Debug").tag(AppConstants.LogLevel.debug)
                    Text("Info").tag(AppConstants.LogLevel.info)
                    Text("Warn").tag(AppConstants.LogLevel.warn)
                    Text("Error").tag(AppConstants.LogLevel.error)
                }

                Picker("Log Format", selection: $config.logFormat) {
                    Text("Text").tag("text")
                    Text("JSON").tag("json")
                }
            } header: {
                Text("Output")
            }

            Section {
                LabeledContent("Log File") {
                    Text(DefaultLogDir() + "/")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Unified Logging") {
                    Text("subsystem: \(AppConstants.bundleIdentifier)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Log Destinations")
            }

            saveStatus
        }
        .formStyle(.grouped)
    }

    /// Logs tab: embedded `LogViewerView` showing this configuration's runner output.
    /// The log store is injected via `@EnvironmentObject` so it matches the
    /// runner instance selected in the sidebar.
    private var logsTab: some View {
        LogViewerView()
            .environmentObject(logStore)
    }

    // MARK: - Save Status Indicator

    /// Inline save feedback shown at the bottom of each tab.
    /// Shows either an error message (red with warning icon) or a transient
    /// "Changes saved" confirmation (green with checkmark) that auto-hides
    /// after 2 seconds.
    @ViewBuilder
    private var saveStatus: some View {
        if let error = errorMessage {
            HStack {
                Image(systemName: AppConstants.SFSymbol.warning)
                    .foregroundColor(.red)
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }

        if showSaveSuccess {
            HStack {
                Image(systemName: AppConstants.SFSymbol.success)
                    .foregroundColor(.green)
                Text("Changes saved")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
    }

    // MARK: - Helpers

    /// Loads the config from disk and infers UI toggle states (auth method,
    /// key source) from the loaded values. Falls back to clean defaults on error.
    ///
    /// The `isLoading` flag is set during load and cleared after a brief delay
    /// to suppress `onChange` handlers from triggering autosave during the
    /// initial population of fields.
    private func loadConfig() {
        isLoading = true
        do {
            config = try AppConfig.load(from: configPath)
            // Infer which auth method to display based on what credentials are present.
            useGitHubApp = config.usesGitHubApp || config.token.isEmpty
            useKeyFile = !config.appPrivateKeyPath.isEmpty
        } catch {
            config = AppConfig()
            useGitHubApp = true
            useKeyFile = false
        }
        hasUnsavedChanges = false
        // Brief delay before enabling autosave to let SwiftUI finish binding
        // the loaded values without triggering onChange handlers.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isLoading = false
        }
    }

    /// Saves the config to disk, stripping auth fields for the unused auth method
    /// to avoid leaking stale credentials in the YAML file. If the runner is
    /// active, triggers a restart so the new settings take effect immediately.
    ///
    /// This is called on every field change (debounced by SwiftUI's onChange
    /// coalescing). The "Changes saved" indicator auto-hides after 2 seconds.
    private func autosave() {
        guard hasUnsavedChanges else { return }

        // Zero out credentials for the auth method that is NOT selected,
        // so the YAML file never contains both a PAT and App credentials.
        // This prevents confusing errors when the Go CLI finds both and
        // doesn't know which to use.
        var toSave = config
        if useGitHubApp {
            toSave.token = ""
            if useKeyFile {
                toSave.appPrivateKey = ""
            } else {
                toSave.appPrivateKeyPath = ""
            }
        } else {
            toSave.appClientID = ""
            toSave.appInstallationID = nil
            toSave.appPrivateKeyPath = ""
            toSave.appPrivateKey = ""
        }

        do {
            try toSave.save(to: configPath)
            errorMessage = nil
            showSaveSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSaveSuccess = false
            }
            // Restart the runner with the new config if it was running,
            // so changes take effect without manual stop/start.
            if runner.state == .running || runner.state == .starting {
                Task { await runner.restart() }
            }
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Shared Helpers (used by both ConfigEditorView and WizardView)

/// Returns the macOS-standard log directory for this app.
/// Follows the `~/Library/Logs/<app-name>/` convention.
func DefaultLogDir() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Logs/\(AppConstants.appDirectoryName)"
}

/// Styled label for form fields (subheadline weight).
/// Used across config editor and wizard for consistent field labeling.
func fieldLabel(_ text: String) -> some View {
    Text(text)
        .font(.subheadline)
        .fontWeight(.medium)
}

/// Small secondary-color hint text shown below form fields to provide
/// context about what a field does or what format is expected.
func fieldHint(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundColor(.secondary)
}
