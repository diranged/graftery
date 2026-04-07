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

/// A step-by-step setup wizard shown on first launch (or when the user creates
/// a new configuration). Guides the user through all required configuration:
///
/// 1. **Config Name** — unique identifier for this runner configuration
/// 2. **GitHub Connection** — org or repo URL for scale set registration
/// 3. **Authentication** — GitHub App credentials or PAT
/// 4. **VM Settings** — Tart base image and runner concurrency
/// 5. **Runner Settings** — scale set name, labels, group, prefix
/// 6. **Logging** — log level and format
///
/// On completion, saves the config YAML and invokes `onComplete` with the
/// config name so the caller can add it to the store and start the runner.
struct WizardView: View {
    @State private var config = AppConfig()
    @State private var configName = ""
    @State private var useGitHubApp = true
    @State private var useKeyFile = false
    @State private var currentStep = 1
    @State private var errorMessage: String?
    @State private var showFileImporter = false

    private let totalSteps = 6

    /// Called after successful save with the config name. The caller
    /// (`GrafteryApp`) uses this to add the config to `RunnerStore`
    /// and optionally auto-start the runner.
    private let onComplete: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(onComplete: ((String) -> Void)? = nil) {
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: title, step counter, and progress dots
            VStack(spacing: 4) {
                Text("\(AppConstants.appName) Setup")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Step \(currentStep) of \(totalSteps)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Step indicator dots — green for completed, accent for current, gray for future
                HStack(spacing: 8) {
                    ForEach(1...totalSteps, id: \.self) { step in
                        Circle()
                            .fill(stepColor(for: step))
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Step content — each step is a VStack of form fields
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch currentStep {
                    case 1: stepConfigName
                    case 2: stepGitHubConnection
                    case 3: stepAuthentication
                    case 4: stepVMSettings
                    case 5: stepRunnerSettings
                    case 6: stepLogging
                    default: EmptyView()
                    }
                }
                .padding(24)
            }

            Divider()

            // Navigation: Back/Continue buttons with inline validation errors
            HStack {
                if currentStep > 1 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                if currentStep < totalSteps {
                    Button("Continue") {
                        if let err = validateCurrentStep() {
                            errorMessage = err
                        } else {
                            errorMessage = nil
                            withAnimation { currentStep += 1 }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Save & Close") {
                        if let err = validateAll() {
                            errorMessage = err
                        } else {
                            errorMessage = nil
                            saveAndClose()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .onAppear(perform: loadConfig)
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

    // MARK: - Steps

    /// Step 1: Name the configuration. The name is used as the YAML filename
    /// stem and the display name in the sidebar, so it must be filesystem-safe.
    private var stepConfigName: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name Your Configuration")
                .font(.headline)
            Text("Choose a name for this runner configuration. Each configuration runs as an independent runner scale set.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            fieldLabel("Configuration Name")
            TextField("macos-xcode16", text: $configName)
                .textFieldStyle(.roundedBorder)
            fieldHint("Used as the filename and display name. Letters, numbers, and hyphens only.")
        }
    }

    /// Step 2: GitHub org/repo URL for scale set registration.
    private var stepGitHubConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub Connection")
                .font(.headline)
            Text("Enter the org or repo URL where this runner scale set will be registered.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            fieldLabel("Registration URL")
            TextField("https://github.com/my-org", text: $config.url)
                .textFieldStyle(.roundedBorder)
            fieldHint("e.g. https://github.com/my-org or https://github.com/my-org/my-repo")
        }
    }

    /// Step 3: Auth method selection (GitHub App vs PAT) and credential entry.
    /// GitHub App is recommended because PATs expire and have broader scope.
    private var stepAuthentication: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Authentication")
                .font(.headline)
            Text("Choose how to authenticate with GitHub.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Auth Method", selection: $useGitHubApp) {
                Text("GitHub App (recommended)").tag(true)
                Text("Personal Access Token").tag(false)
            }
            .pickerStyle(.segmented)

            if useGitHubApp {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("App Client ID")
                    TextField("Iv1.abc123...", text: $config.appClientID)
                        .textFieldStyle(.roundedBorder)

                    fieldLabel("App Installation ID")
                    TextField("12345678", text: $config.installationIDString)
                        .textFieldStyle(.roundedBorder)

                    fieldLabel("Private Key")
                    Picker("Key Source", selection: $useKeyFile) {
                        Text("Paste Key Contents").tag(false)
                        Text("Key File Path").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if useKeyFile {
                        HStack {
                            TextField("/path/to/private-key.pem", text: $config.appPrivateKeyPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                showFileImporter = true
                            }
                        }
                        fieldHint("Path to the PEM file downloaded from GitHub.")
                    } else {
                        TextEditor(text: $config.appPrivateKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120, maxHeight: 200)
                            .border(Color(nsColor: .separatorColor))
                        fieldHint("Paste the contents of your PEM private key.")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Personal Access Token")
                    SecureField("ghp_xxxx...", text: $config.token)
                        .textFieldStyle(.roundedBorder)
                    fieldHint("A classic or fine-grained PAT with appropriate permissions.")
                }
            }

            Link("How to create a GitHub App",
                 destination: URL(string: AppConstants.gitHubAppDocsURL)!)
                .font(.caption)
        }
    }

    /// Step 4: Tart VM base image and min/max runner concurrency.
    private var stepVMSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VM Settings")
                .font(.headline)
            Text("Configure the Tart virtual machine parameters.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            fieldLabel("Base Image")
            TextField("ghcr.io/cirruslabs/macos-runner:sonoma", text: $config.baseImage)
                .textFieldStyle(.roundedBorder)
            fieldHint("The Tart VM image to clone for each runner.")

            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    fieldLabel("Max Runners")
                    Stepper(value: $config.maxRunners, in: 1...10) {
                        Text("\(config.maxRunners)")
                            .monospacedDigit()
                    }
                }
                VStack(alignment: .leading) {
                    fieldLabel("Min Runners")
                    Stepper(value: $config.minRunners, in: 0...10) {
                        Text("\(config.minRunners)")
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Step 5: Scale set name, workflow labels, runner group, and VM name prefix.
    private var stepRunnerSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Runner Settings")
                .font(.headline)
            Text("Scale set name and label configuration.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            fieldLabel("Name")
            TextField("my-macos-runner", text: $config.name)
                .textFieldStyle(.roundedBorder)
            fieldHint("The scale set name, also used as the runs-on label.")

            fieldLabel("Labels")
            TextField("self-hosted, macOS, ARM64", text: $config.labelsString)
                .textFieldStyle(.roundedBorder)
            fieldHint("Comma-separated. Leave blank to use the name as the sole label.")

            fieldLabel("Runner Group")
            TextField("default", text: $config.runnerGroup)
                .textFieldStyle(.roundedBorder)

            fieldLabel("Runner Prefix")
            TextField("runner", text: $config.runnerPrefix)
                .textFieldStyle(.roundedBorder)
            fieldHint("VM name prefix, also used for orphan detection.")
        }
    }

    /// Step 6: Log level and format configuration. This is the final step
    /// before save. Most users can leave defaults (info/text) and move on.
    private var stepLogging: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logging")
                .font(.headline)
            Text("Adjust log verbosity and format.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 24) {
                VStack(alignment: .leading) {
                    fieldLabel("Log Level")
                    Picker("", selection: $config.logLevel) {
                        Text("Debug").tag(AppConstants.LogLevel.debug)
                        Text("Info").tag(AppConstants.LogLevel.info)
                        Text("Warn").tag(AppConstants.LogLevel.warn)
                        Text("Error").tag(AppConstants.LogLevel.error)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                VStack(alignment: .leading) {
                    fieldLabel("Log Format")
                    Picker("", selection: $config.logFormat) {
                        Text("Text").tag("text")
                        Text("JSON").tag("json")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Returns the indicator dot color for a given step number.
    /// Green for completed steps, accent color for the current step,
    /// and separator color (gray) for future steps.
    private func stepColor(for step: Int) -> Color {
        if step < currentStep { return .green }
        if step == currentStep { return .accentColor }
        return Color(nsColor: .separatorColor)
    }

    /// Initializes fresh defaults for the wizard. Called on appear to ensure
    /// a clean slate even if the view was previously used and dismissed.
    private func loadConfig() {
        config = AppConfig()
        useGitHubApp = true
        useKeyFile = false
    }

    /// Validates only the current step; returns an error message or nil.
    private func validateCurrentStep() -> String? {
        return validateStep(currentStep)
    }

    /// Per-step validation rules. Returns a user-facing error string or nil if valid.
    /// Each step validates only its own fields so the user gets immediate
    /// feedback without being blocked by incomplete future steps.
    private func validateStep(_ step: Int) -> String? {
        switch step {
        case 1: // Config name — must be non-empty, filesystem-safe, and unique
            let trimmed = configName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return "Configuration name is required."
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return "Name can only contain letters, numbers, hyphens, and underscores."
            }
            if FileManager.default.fileExists(atPath: AppConfig.configPath(forName: trimmed)) {
                return "A configuration named '\(trimmed)' already exists."
            }
        case 2: // GitHub connection — URL is required
            if config.url.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Registration URL is required."
            }
        case 3: // Authentication — validate based on selected auth method
            if useGitHubApp {
                if config.appClientID.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "App Client ID is required."
                }
                if config.appInstallationID == nil {
                    return "App Installation ID is required."
                }
                if useKeyFile && config.appPrivateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "Private key file path is required."
                }
                if !useKeyFile && config.appPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Private key contents are required."
                }
            } else {
                if config.token.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "Personal Access Token is required."
                }
            }
        case 4: // VM settings — base image is required
            if config.baseImage.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Base image is required."
            }
        case 5: // Runner settings — name is required
            if config.name.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Runner name is required."
            }
        default:
            break
        }
        return nil
    }

    /// Validates all steps sequentially; returns the first error found.
    /// Used by the final "Save & Close" button to catch any issues the
    /// user might have skipped past.
    private func validateAll() -> String? {
        for step in 1...totalSteps {
            if let err = validateStep(step) {
                return err
            }
        }
        return nil
    }

    /// Strips unused auth fields, saves the config YAML, calls `onComplete`,
    /// and dismisses the wizard window.
    ///
    /// Auth field stripping ensures the YAML file only contains credentials
    /// for the selected method, preventing the Go CLI from finding conflicting
    /// auth sources.
    private func saveAndClose() {
        if useGitHubApp {
            config.token = ""
            if useKeyFile {
                config.appPrivateKey = ""
            } else {
                config.appPrivateKeyPath = ""
            }
        } else {
            config.appClientID = ""
            config.appInstallationID = nil
            config.appPrivateKeyPath = ""
            config.appPrivateKey = ""
        }

        let savePath = AppConfig.configPath(forName: configName)
        do {
            try config.save(to: savePath)
            onComplete?(configName)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}
