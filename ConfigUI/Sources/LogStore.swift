import Foundation
import os

/// Shared log buffer that collects parsed log lines from the CLI subprocess.
///
/// Both `RunnerManager` (producer) and `LogViewerView` (consumer) hold a
/// reference to the same instance. Lines are also echoed to macOS Unified
/// Logging so they appear in Console.app and `log stream`.
///
/// The buffer is kept in memory (not persisted to disk) because the CLI
/// already writes its own log files. This store exists purely for the
/// real-time log viewer in the UI.
@MainActor
class LogStore: ObservableObject {

    /// A single parsed log line from the CLI's slog text-format output.
    ///
    /// The `raw` field preserves the original line for clipboard copy and
    /// OSLog echo. The parsed fields (`timestamp`, `level`, `message`) are
    /// used for display formatting and level-based filtering.
    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        /// Formatted time string (HH:MM:SS), extracted from the slog timestamp.
        let timestamp: String
        /// Log level string (e.g., "INFO", "ERROR"), extracted from slog output.
        let level: String
        /// The human-readable message, extracted from the slog `msg` field.
        let message: String
        /// The original unparsed line, preserved for copy-to-clipboard and OSLog echo.
        let raw: String
    }

    /// The log lines currently in the buffer. Observed by `LogViewerView`
    /// to drive real-time display updates.
    @Published var lines: [LogLine] = []

    /// macOS Unified Logging logger — echoes CLI output so Console.app and
    /// `log stream --predicate 'subsystem == "com.diranged.graftery"'`
    /// can display it alongside system logs.
    private let osLogger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "cli"
    )

    /// Maximum number of lines kept in memory before trimming occurs.
    private let maxLines = AppConstants.logMaxLines

    /// After trimming, the buffer is reduced to this many lines. The gap
    /// between `maxLines` and `trimTarget` avoids trimming on every single
    /// append call, which would cause excessive array copying.
    private let trimTarget = AppConstants.logTrimTarget

    /// Appends new raw text (possibly containing multiple lines) from the
    /// CLI pipe. Each line is parsed from slog text format, appended to the
    /// buffer, and echoed to macOS Unified Logging. The buffer is trimmed
    /// if it exceeds `maxLines`.
    ///
    /// - Parameter rawOutput: Raw string data from the CLI's stdout/stderr pipe.
    func append(rawOutput: String) {
        let newLines = rawOutput
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { parseSlogLine($0) }

        guard !newLines.isEmpty else { return }

        for line in newLines {
            echoToOSLog(line)
        }

        lines.append(contentsOf: newLines)

        // Trim from the front (oldest lines) when the buffer grows too large.
        if lines.count > maxLines {
            lines.removeFirst(lines.count - trimTarget)
        }
    }

    /// Removes all stored log lines. Called by the "Clear" button in the log viewer.
    func clear() {
        lines.removeAll()
    }

    // MARK: - Parsing

    /// Parses a single slog text-format line into a `LogLine`.
    ///
    /// Go's slog text format looks like:
    /// ```
    /// time=2024-01-15T10:30:45.123Z level=INFO msg="message here" key=value ...
    /// ```
    ///
    /// If parsing fails (e.g., non-slog output from the CLI), the raw line
    /// is used as the message with empty timestamp and default "info" level.
    ///
    /// - Parameter line: A single line of CLI output.
    /// - Returns: A parsed `LogLine`, or nil if the line is empty/whitespace-only.
    private func parseSlogLine(_ line: String) -> LogLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let timestamp = extractValue(from: trimmed, key: AppConstants.SlogKey.time)
            .flatMap { formatTimestamp($0) } ?? ""
        let level = extractValue(from: trimmed, key: AppConstants.SlogKey.level)
            ?? AppConstants.LogLevel.info
        let rawMessage = extractValue(from: trimmed, key: AppConstants.SlogKey.msg) ?? trimmed
        // Go's slog text handler escapes special characters (\t, \n, \\).
        // Unescape them for display in the log viewer.
        let message = rawMessage
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")

        return LogLine(timestamp: timestamp, level: level, message: message, raw: trimmed)
    }

    /// Extracts the value for a given key from a slog `key=value` line.
    ///
    /// Handles two forms:
    /// - Quoted: `key="value with spaces"` — returns content between quotes
    /// - Unquoted: `key=value` — returns content up to the next space
    ///
    /// - Parameters:
    ///   - line: The full slog output line.
    ///   - key: The key name to search for (e.g., "time", "level", "msg").
    /// - Returns: The extracted value string, or nil if the key is not found.
    private func extractValue(from line: String, key: String) -> String? {
        let prefix = "\(key)="
        guard let range = line.range(of: prefix) else { return nil }

        let afterKey = line[range.upperBound...]
        if afterKey.hasPrefix("\"") {
            let content = afterKey.dropFirst()
            if let endQuote = content.firstIndex(of: "\"") {
                return String(content[..<endQuote])
            }
            return String(content)
        } else {
            let endIndex = afterKey.firstIndex(of: " ") ?? afterKey.endIndex
            return String(afterKey[..<endIndex])
        }
    }

    /// Formats an ISO 8601 timestamp to just the `HH:MM:SS` portion for compact
    /// display in the log viewer. The full timestamp is preserved in the raw line.
    ///
    /// - Parameter ts: An ISO timestamp like "2024-01-15T10:30:45.123-07:00".
    /// - Returns: The "10:30:45" portion, or the last 8 characters as fallback.
    private func formatTimestamp(_ ts: String) -> String {
        if let tIdx = ts.firstIndex(of: "T") {
            let timeStr = ts[ts.index(after: tIdx)...]
            return String(timeStr.prefix(8))
        }
        return String(ts.suffix(8))
    }

    // MARK: - OSLog Echo

    /// Re-logs a parsed line to macOS Unified Logging at the appropriate level.
    /// This allows `Console.app` and `log stream` to show CLI output alongside
    /// system logs, which is useful for debugging when the app UI is not visible.
    ///
    /// The `.public` privacy qualifier is used because log messages do not
    /// contain sensitive user data (they are operational status messages).
    private func echoToOSLog(_ line: LogLine) {
        switch line.level.lowercased() {
        case AppConstants.LogLevel.debug:
            osLogger.debug("\(line.raw, privacy: .public)")
        case AppConstants.LogLevel.warn, AppConstants.LogLevel.warning:
            osLogger.warning("\(line.raw, privacy: .public)")
        case AppConstants.LogLevel.error:
            osLogger.error("\(line.raw, privacy: .public)")
        default:
            osLogger.info("\(line.raw, privacy: .public)")
        }
    }
}
