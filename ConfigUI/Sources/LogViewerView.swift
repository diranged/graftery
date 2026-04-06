import SwiftUI
import AppKit

/// Real-time log viewer that displays entries from the shared `LogStore`,
/// which is fed by the CLI subprocess pipe.
///
/// Features:
/// - **Search filtering**: free-text search across raw log lines
/// - **Level filtering**: show only lines at or above a selected severity
/// - **Auto-scroll**: automatically scrolls to the bottom on new output
/// - **Copy**: copies all visible (filtered) lines to the clipboard
/// - **Clear**: removes all lines from the log store
///
/// Uses `NSTextView` (via `LogTextView`) instead of SwiftUI's `Text` because
/// SwiftUI does not support multi-line text selection in scrolling containers
/// like `LazyVStack`. `NSTextView` provides native Cmd+C copy and drag-to-select.
struct LogViewerView: View {
    @EnvironmentObject var logStore: LogStore

    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var levelFilter = AppConstants.LogLevel.all

    /// Returns log lines matching both the search text and level filter.
    /// Filtering is done on every body evaluation, which is acceptable
    /// because LogStore caps the buffer at 10K lines.
    var filteredLines: [LogStore.LogLine] {
        logStore.lines.filter { line in
            let matchesLevel: Bool
            switch levelFilter {
            case AppConstants.LogLevel.error:
                matchesLevel = [AppConstants.LogLevel.error, AppConstants.LogLevel.fault]
                    .contains(line.level.lowercased())
            case AppConstants.LogLevel.warn:
                matchesLevel = [
                    AppConstants.LogLevel.error,
                    AppConstants.LogLevel.fault,
                    AppConstants.LogLevel.warn,
                    AppConstants.LogLevel.warning,
                    AppConstants.LogLevel.default,
                ].contains(line.level.lowercased())
            case AppConstants.LogLevel.info:
                matchesLevel = line.level.lowercased() != AppConstants.LogLevel.debug
            default:
                matchesLevel = true
            }

            let matchesSearch = searchText.isEmpty || line.raw.localizedCaseInsensitiveContains(searchText)

            return matchesLevel && matchesSearch
        }
    }

    /// Formats all filtered lines into a single `NSAttributedString` for the
    /// `NSTextView`. Each line is colored by severity level:
    /// - Error/Fault: red
    /// - Warn/Warning: orange
    /// - Debug: secondary (dimmed)
    /// - Info/default: primary label color
    private var formattedLogText: NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: AppConstants.logFontSize, weight: .regular)

        for line in filteredLines {
            let color: NSColor
            switch line.level.lowercased() {
            case AppConstants.LogLevel.error, AppConstants.LogLevel.fault:
                color = .systemRed
            case AppConstants.LogLevel.warn, AppConstants.LogLevel.warning, AppConstants.LogLevel.default:
                color = .systemOrange
            case AppConstants.LogLevel.debug:
                color = .secondaryLabelColor
            default:
                color = .labelColor
            }

            let paddedLevel = line.level.uppercased()
                .padding(toLength: AppConstants.logLevelPadLength, withPad: " ", startingAt: 0)
            let text = "\(line.timestamp)  \(paddedLevel)  \(line.message)\n"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: search field, level picker, auto-scroll toggle, copy, clear
            HStack(spacing: 12) {
                // Search field with inline clear button
                HStack {
                    Image(systemName: AppConstants.SFSymbol.search)
                        .foregroundColor(.secondary)
                    TextField("Filter logs...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: AppConstants.SFSymbol.clearField)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                // Level filter picker — "Info+" means info and above (warn, error)
                Picker("Level", selection: $levelFilter) {
                    Text("All").tag(AppConstants.LogLevel.all)
                    Text("Debug+").tag(AppConstants.LogLevel.debug)
                    Text("Info+").tag(AppConstants.LogLevel.info)
                    Text("Warn+").tag(AppConstants.LogLevel.warn)
                    Text("Error").tag(AppConstants.LogLevel.error)
                }
                .frame(width: 100)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Spacer()

                // Copy all filtered log lines to the system clipboard
                Button {
                    let text = filteredLines.map(\.raw).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: AppConstants.SFSymbol.copy)
                }
                .help("Copy all logs to clipboard")

                // Clear the entire log buffer (not just filtered view)
                Button {
                    logStore.clear()
                } label: {
                    Image(systemName: AppConstants.SFSymbol.trash)
                }
                .help("Clear logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log content area: NSTextView wrapped in NSScrollView for native
            // text selection, Cmd+C copy, and drag-to-select across lines.
            LogTextView(
                attributedText: formattedLogText,
                autoScroll: autoScroll
            )
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Status bar: shows filtered/total line counts
            HStack {
                Text("\(filteredLines.count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if filteredLines.count != logStore.lines.count {
                    Text("(\(logStore.lines.count) total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

/// `NSViewRepresentable` wrapper around `NSTextView` for proper text selection,
/// Cmd+C copy, and drag-to-select across multiple lines.
///
/// SwiftUI's `Text` views do not support multi-line selection in scrollable
/// containers (`LazyVStack`, `ScrollView`), making them unsuitable for a log
/// viewer where users need to select and copy arbitrary ranges of text.
/// `NSTextView` provides this natively via AppKit.
struct LogTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let autoScroll: Bool

    /// Creates the `NSScrollView` + `NSTextView` pair. The text view is
    /// configured as read-only and selectable, with smart quotes and dashes
    /// disabled (they corrupt log output like JSON and paths).
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 4)
        // Disable smart substitutions that would corrupt log content
        // (e.g., turning straight quotes into curly quotes in JSON).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        return scrollView
    }

    /// Updates the text content and optionally auto-scrolls to the bottom.
    /// Auto-scroll only triggers when new content has been appended (length
    /// increased), not on every update, to avoid fighting the user's scroll
    /// position during re-renders.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        let previousLength = textView.textStorage?.length ?? 0

        textView.textStorage?.setAttributedString(attributedText)

        if autoScroll && attributedText.length > previousLength {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
