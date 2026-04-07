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

// MARK: - Application Identity

/// Centralized constants for the Graftery app. Extracted from scattered
/// string literals to ensure consistency across the codebase and make refactoring
/// safer. If a string appears in more than one file, or carries semantic meaning
/// beyond its literal value, it belongs here.
enum AppConstants {

    /// The current application version. Shown in the About window and the
    /// menu bar header. Bump this for each release.
    static let appVersion = "0.1.0"

    /// Human-readable application name used in window titles and UI labels.
    static let appName = "Graftery"

    /// The reverse-DNS bundle identifier used for macOS Unified Logging
    /// (subsystem parameter) and Application Support directory naming.
    static let bundleIdentifier = "com.diranged.graftery"

    /// The directory name used under ~/Library/Application Support/ and
    /// ~/Library/Logs/. Kept separate from `bundleIdentifier` because the
    /// filesystem name omits the "com." prefix by convention.
    static let appDirectoryName = "graftery"

    /// The Go CLI binary name that RunnerManager searches for inside the
    /// app bundle (Contents/Resources/) and next to the executable.
    static let cliBinaryName = "graftery-cli"

    /// The tart binary name used when scanning PATH directories.
    static let tartBinaryName = "tart"

    /// Project GitHub URL shown in About view and config file headers.
    static let projectURL = "https://github.com/diranged/graftery"

    /// Tart project homepage shown in About view.
    static let tartURL = "https://tart.run"

    /// Actions scaleset project URL shown in About view.
    static let actionsScalesetURL = "https://github.com/actions/scaleset"

    /// GitHub App documentation URL shown in auth configuration views.
    static let gitHubAppDocsURL = "https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app"

    // MARK: - Window / Scene IDs

    /// These IDs must match the `id:` parameter on each `Window(... id:)` scene
    /// declaration in GrafteryApp. If they diverge, `openWindow(id:)` calls
    /// will silently fail with no visible error.
    enum WindowID {
        static let configurations = "configurations"
        static let wizard = "wizard"
        static let about = "about"
    }

    // MARK: - Notifications

    /// Custom notification names used for cross-component communication.
    /// The app uses notifications (rather than delegates or closures) to bridge
    /// between AppKit (StatusBarController) and SwiftUI (GrafteryApp) because
    /// StatusBarController cannot hold an @Environment(\.openWindow) reference.
    enum Notifications {
        static let openWindowRequest = Notification.Name("openWindowRequest")
    }

    // MARK: - UserDefaults Keys

    enum UserDefaultsKeys {
        /// Controls whether macOS restores windows from the previous session.
        /// Set to `false` on launch because this is a menu-bar-only app and
        /// restoring windows would show unexpected UI on startup.
        ///
        /// There is no AppKit/SwiftUI constant for this key — it is a documented
        /// NSUserDefaults key in Apple's Window Restoration documentation.
        /// See: https://developer.apple.com/documentation/appkit/nsquitrequestresponse
        static let quitAlwaysKeepsWindows = "NSQuitAlwaysKeepsWindows"
    }

    // MARK: - SF Symbols

    /// SF Symbol names used throughout the UI. Centralizing these prevents
    /// typos (which compile fine but show an empty image at runtime) and
    /// makes it easy to swap icons globally.
    enum SFSymbol {
        static let appIcon = "play.circle"
        static let appIconFilled = "play.circle.fill"
        static let search = "magnifyingglass"
        static let clearField = "xmark.circle.fill"
        static let copy = "doc.on.doc"
        static let trash = "trash"
        static let warning = "exclamationmark.triangle.fill"
        static let success = "checkmark.circle.fill"
        static let add = "plus"
        static let emptyState = "server.rack"

        /// Tab icons for the config editor, keyed to ConfigTab cases.
        enum Tab {
            static let general = "gear"
            static let auth = "lock.shield"
            static let runners = "server.rack"
            static let provisioning = "hammer"
            static let logging = "doc.text"
            static let logs = "terminal"
        }
    }

    // MARK: - Control Socket

    /// Prefix for Unix domain socket paths. Each runner gets its own socket
    /// at `/tmp/arc-runner-<configName>.sock`.
    static let controlSocketPrefix = "/tmp/arc-runner-"
    static let controlSocketSuffix = ".sock"

    // MARK: - Status Strings

    /// String values returned by the Go CLI's control socket `/status` endpoint.
    /// These must stay in sync with the Go `State` type in status.go.
    enum CLIState {
        static let running = "running"
        static let error = "error"
        static let stopping = "stopping"
        static let idle = "idle"
    }

    /// Display strings used in the menu bar dropdown for runner state.
    enum MenuStatus {
        static let disabled = "disabled"
        static let stopped = "stopped"
        static let error = "error"
        static let running = "running"
        static let starting = "starting"
        static let stopping = "stopping"
    }

    /// Unicode characters used as action button icons in the NSMenu custom view.
    /// We use Unicode instead of SF Symbols because NSMenu item views need
    /// simple text buttons that render reliably at menu-item size.
    enum MenuIcon {
        static let play = "▶"
        static let stop = "■"
        static let waiting = "⏳"
    }

    // MARK: - Log Levels

    /// Log level filter tags used in the level picker and slog parsing.
    /// These match the Go slog text format level strings.
    enum LogLevel {
        static let all = "all"
        static let debug = "debug"
        static let info = "info"
        static let warn = "warn"
        static let warning = "warning"
        static let error = "error"
        static let fault = "fault"
        static let `default` = "default"
    }

    // MARK: - Slog Parsing Keys

    /// Key names in Go's slog text-format output lines.
    /// Format: `time=... level=... msg="..." key=value`
    enum SlogKey {
        static let time = "time"
        static let level = "level"
        static let msg = "msg"
    }

    // MARK: - Config File

    /// Header comment prepended to every YAML config file. Matches the format
    /// used by the Go CLI so either side can read/write the same file.
    static let configFileHeader = "# graftery configuration\n# See: \(projectURL)\n\n"

    /// The file extension used for per-configuration YAML files.
    static let configFileExtension = ".yaml"

    /// Suffix appended to legacy config files after migration to multi-config layout.
    static let migratedFileSuffix = ".migrated"

    /// The default name assigned to migrated legacy configurations.
    static let defaultConfigName = "default"

    // MARK: - Provisioning Script Directories

    /// Subdirectories created under the scripts directory for user customization.
    /// These are also documented in the provisioning tab help text.
    static let provisioningSubdirs = ["bake.d", "hooks/pre.d", "hooks/post.d"]

    // MARK: - Polling Intervals

    /// How often the control socket is polled for state updates (seconds).
    /// 2 seconds balances responsiveness against CPU overhead.
    static let controlSocketPollInterval: TimeInterval = 2.0

    /// How often the open NSMenu is refreshed to show state changes (seconds).
    static let menuRefreshInterval: TimeInterval = 1.0

    // MARK: - Log Store Limits

    /// Maximum number of log lines kept in memory before trimming.
    static let logMaxLines = 10_000

    /// After trimming, the buffer is reduced to this size. The gap between
    /// maxLines and trimTarget avoids trimming on every single append.
    static let logTrimTarget = 8_000

    // MARK: - Recent Output Buffer

    /// Number of recent CLI output lines kept for error reporting when
    /// the subprocess exits unexpectedly.
    static let recentOutputLimit = 5

    // MARK: - UI Dimensions

    /// Font size for the monospaced log viewer text.
    static let logFontSize: CGFloat = 11

    /// Font size for the action button in the menu item custom view.
    static let menuItemButtonFontSize: CGFloat = 13

    /// Level label padding width in the formatted log output.
    static let logLevelPadLength = 5

    /// Width/height of the launch banner panel.
    static let bannerWidth: CGFloat = 360
    static let bannerHeight: CGFloat = 100
}
