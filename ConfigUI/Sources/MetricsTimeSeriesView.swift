import SwiftUI
import Charts

/// A single data point in the metrics history buffer, representing a snapshot
/// of CPU and memory usage at a specific moment in time.
///
/// Data points are appended by `RunnerManager.pollControlSocket()` every poll
/// cycle (~2 seconds) and consumed by `MetricsTimeSeriesView` to render
/// time-series area/line charts.
struct MetricsDataPoint: Identifiable {
    /// Unique identifier for SwiftUI list diffing.
    let id = UUID()

    /// When this sample was recorded.
    let timestamp: Date

    /// CPU usage as a percentage of total host capacity (0--100).
    /// This is the sum of per-runner CPU divided by the host's core count,
    /// so 100% means the runners are fully saturating every core.
    let cpuPercent: Double

    /// Memory usage as a percentage of total host memory (0--100).
    /// Computed as `totalRunnerRSS / hostMemoryTotal * 100`.
    let memoryPercent: Double
}

/// Selectable time range for the metrics time-series graph.
///
/// The user picks a range from a segmented control; only data points within
/// that window (relative to "now") are displayed in the charts.
enum MetricsTimeRange: String, CaseIterable, Identifiable {
    /// Show the last 5 minutes of data.
    case fiveMin = "5m"
    /// Show the last 15 minutes of data.
    case fifteenMin = "15m"
    /// Show the last 30 minutes of data.
    case thirtyMin = "30m"

    /// Conformance to `Identifiable` using the raw string value.
    var id: String { rawValue }

    /// Duration of this range in seconds.
    var seconds: TimeInterval {
        switch self {
        case .fiveMin: return 5 * 60
        case .fifteenMin: return 15 * 60
        case .thirtyMin: return 30 * 60
        }
    }

    /// Human-readable label shown in the segmented picker (e.g., "5 min").
    var label: String {
        switch self {
        case .fiveMin: return "5 min"
        case .fifteenMin: return "15 min"
        case .thirtyMin: return "30 min"
        }
    }
}

/// Side-by-side CPU and memory time-series charts displayed in the
/// configuration detail pane header, between the config name and the
/// status badge.
///
/// Each metric is rendered as a stacked area chart (filled region) with a
/// line overlay, using Catmull-Rom interpolation for smooth curves. The Y axis
/// is fixed at 0--100% so the two charts are visually comparable.
///
/// A segmented picker at the bottom lets the user choose among 5m / 15m / 30m
/// time windows. Data points outside the selected window are filtered out
/// before rendering.
struct MetricsTimeSeriesView: View {
    /// The full metrics history buffer (not yet filtered by time range).
    /// Passed in from `RunnerManager.metricsHistory`.
    let history: [MetricsDataPoint]

    /// The currently selected time window, controlled by the segmented picker.
    @State private var timeRange: MetricsTimeRange = .fiveMin

    /// Returns only data points that fall within the selected time range.
    private var filteredData: [MetricsDataPoint] {
        let cutoff = Date().addingTimeInterval(-timeRange.seconds)
        return history.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                singleChart(
                    title: "CPU",
                    color: .green,
                    value: { $0.cpuPercent }
                )
                singleChart(
                    title: "Memory",
                    color: .cyan,
                    value: { $0.memoryPercent }
                )
            }
            timeRangePicker
        }
    }

    /// Builds a single time-series chart (area + line) for one metric.
    ///
    /// - Parameters:
    ///   - title: The label displayed above the chart (e.g., "CPU" or "Memory").
    ///   - color: The accent color for the line, area fill, and legend dot.
    ///   - value: A closure that extracts the relevant percentage from a `MetricsDataPoint`.
    /// - Returns: A SwiftUI view containing the labeled chart.
    private func singleChart(title: String, color: Color, value: @escaping (MetricsDataPoint) -> Double) -> some View {
        VStack(spacing: 2) {
            HStack {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer()
                if let last = filteredData.last {
                    Text(String(format: "%.1f%%", value(last)))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Chart(filteredData) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", value(point))
                )
                .foregroundStyle(color.opacity(0.3))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", value(point))
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { val in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    AxisValueLabel {
                        if let v = val.as(Int.self) {
                            Text("\(v)%")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                    AxisValueLabel(format: .dateTime.minute().second())
                        .font(.system(size: 8))
                }
            }
            .chartLegend(.hidden)
            .frame(height: 50)
        }
    }

    /// Segmented picker for selecting the time range window.
    private var timeRangePicker: some View {
        HStack {
            Spacer()
            Picker("", selection: $timeRange) {
                ForEach(MetricsTimeRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .controlSize(.mini)
        }
    }
}
