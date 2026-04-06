import Foundation
import Yams

/// Configuration for automatic VM image provisioning. Mirrors the Go
/// `ProvisioningConfig` struct in `provisioner.go`.
///
/// Controls how base Tart images are baked with startup scripts, hooks, and
/// user-provided customizations. The baked image is cached locally so VMs
/// start from the prepared image instead of re-running setup on every job.
struct ProvisioningAppConfig: Codable, Equatable {
    /// Path to a directory containing user override scripts.
    /// Expected structure: `bake.d/*.sh`, `hooks/pre.d/*.sh`, `hooks/post.d/*.sh`
    var scriptsDir: String = ""

    /// Override the local tart VM name for the prepared (baked) image.
    /// Empty = auto-generated from base image name and a content hash.
    var preparedImageName: String = ""

    /// When true, skip all embedded scripts and only run user scripts.
    /// Useful for advanced users who want full control over the VM setup.
    var skipBuiltinScripts: Bool = false

    /// Maps Swift camelCase property names to the snake_case keys used in YAML.
    /// These must stay in sync with the Go `ProvisioningConfig` struct tags.
    enum CodingKeys: String, CodingKey {
        case scriptsDir = "scripts_dir"
        case preparedImageName = "prepared_image_name"
        case skipBuiltinScripts = "skip_builtin_scripts"
    }
}

/// Mirrors the Go `Config` struct for YAML serialization.
///
/// Both the Swift UI and Go CLI read/write the same `config.yaml` file, so
/// field names and `CodingKeys` must stay in sync with the Go struct tags.
/// All fields have defaults so a partially-filled config can be loaded without
/// errors — this is important for forward compatibility when new fields are
/// added to either side.
struct AppConfig: Codable, Equatable {
    var url: String = ""
    var name: String = ""
    var appClientID: String = ""
    var appInstallationID: Int64?
    var appPrivateKeyPath: String = ""
    var appPrivateKey: String = ""
    var token: String = ""

    /// The default Tart VM base image. Used as the initial value in the wizard
    /// and config editor when no image is specified.
    static let defaultBaseImage = "ghcr.io/cirruslabs/macos-runner:sonoma"
    var baseImage: String = AppConfig.defaultBaseImage
    var maxRunners: Int = 2
    var minRunners: Int = 0
    var labels: [String]?
    var runnerGroup: String = "default"
    var runnerPrefix: String = "runner"
    var tartPath: String = ""
    var logLevel: String = AppConstants.LogLevel.info
    var logFormat: String = "text"
    var provisioning: ProvisioningAppConfig = ProvisioningAppConfig()

    /// Maps Swift camelCase property names to the snake_case keys used in the YAML file.
    /// These must stay in sync with the Go `Config` struct tags in `config.go`.
    enum CodingKeys: String, CodingKey {
        case url
        case name
        case appClientID = "app_client_id"
        case appInstallationID = "app_installation_id"
        case appPrivateKeyPath = "app_private_key_path"
        case appPrivateKey = "app_private_key"
        case token
        case baseImage = "base_image"
        case maxRunners = "max_runners"
        case minRunners = "min_runners"
        case labels
        case runnerGroup = "runner_group"
        case runnerPrefix = "runner_prefix"
        case tartPath = "tart_path"
        case logLevel = "log_level"
        case logFormat = "log_format"
        case provisioning
    }

    /// The base Application Support directory for this app.
    /// Uses `~/Library/Application Support/graftery/` following
    /// macOS conventions for per-user app data.
    static var appSupportDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/\(AppConstants.appDirectoryName)"
    }

    /// Legacy config file path from the single-config era.
    /// Checked during migration to detect users upgrading from the old layout.
    static var defaultPath: String {
        return "\(appSupportDir)/config\(AppConstants.configFileExtension)"
    }

    /// Directory containing per-configuration YAML files.
    /// Each file is named `<config-name>.yaml`.
    static var configsDir: String {
        return "\(appSupportDir)/configs"
    }

    /// Returns the full config file path for a named configuration.
    ///
    /// - Parameter name: The configuration name (used as the filename stem).
    /// - Returns: Absolute path like `.../configs/my-runner.yaml`.
    static func configPath(forName name: String) -> String {
        return "\(configsDir)/\(name)\(AppConstants.configFileExtension)"
    }

    /// Path to the runner state JSON file that tracks enabled/disabled state
    /// for each configuration. Persisted separately from configs because
    /// the Go CLI doesn't need this information.
    static var runnerStatePath: String {
        return "\(appSupportDir)/runner-state.json"
    }

    /// The default scripts directory for user provisioning overrides.
    static var defaultScriptsDir: String {
        return "\(appSupportDir)/scripts"
    }

    /// Loads a config from a YAML file on disk.
    ///
    /// - Parameter path: Absolute path to the YAML file.
    /// - Returns: A decoded `AppConfig` instance.
    /// - Throws: File I/O errors or YAML decoding errors.
    static func load(from path: String) throws -> AppConfig {
        let url = URL(fileURLWithPath: path)
        let data = try String(contentsOf: url, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }

    /// Saves this config to a YAML file, creating parent directories if needed.
    /// Prepends a human-readable header comment matching the Go CLI's format
    /// so the file looks the same regardless of which side wrote it.
    ///
    /// - Parameter path: Absolute path to write the YAML file.
    /// - Throws: File I/O errors or YAML encoding errors.
    func save(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(self)
        try (AppConstants.configFileHeader + yamlString).write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Computed property that bridges the `[String]?` labels array to/from a
    /// comma-separated string, making it easy to bind to a single `TextField`.
    /// An empty or whitespace-only input is stored as nil (no labels).
    var labelsString: String {
        get { (labels ?? []).joined(separator: ", ") }
        set {
            let parts = newValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            labels = parts.isEmpty ? nil : parts
        }
    }

    /// Whether the user is using GitHub App auth (vs PAT). True if any App
    /// credential field is populated. Used to infer the auth mode when loading
    /// a config that was saved externally (e.g., by the Go CLI).
    var usesGitHubApp: Bool {
        !appClientID.isEmpty || appInstallationID != nil || !appPrivateKeyPath.isEmpty || !appPrivateKey.isEmpty
    }

    /// Bridges the optional `Int64` installation ID to a `String` for `TextField`
    /// binding. Returns empty string for nil, and sets nil for non-numeric input.
    /// This avoids the need for a custom number formatter in the UI.
    var installationIDString: String {
        get { appInstallationID.map { String($0) } ?? "" }
        set { appInstallationID = Int64(newValue) }
    }
}
