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

/// The main management window: a `NavigationSplitView` with a sidebar listing
/// all runner configurations and a detail pane showing the selected config's
/// editor (tabbed) and logs.
///
/// This is the primary UI for day-to-day management after initial setup.
/// Users can start/stop individual runners, toggle auto-start, edit configs,
/// view logs, and delete configurations — all from this single window.
struct ConfigurationsView: View {
    @ObservedObject var store: RunnerStore
    @Environment(\.openWindow) private var openWindow
    @State private var showDeleteConfirmation = false
    @State private var configToDelete: String? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
        // Destructive action confirmation — shown when the user clicks
        // "Delete..." from the context menu. Requires explicit confirmation
        // because deletion stops the runner and removes the config file.
        .alert("Delete Configuration", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let name = configToDelete {
                    Task { await store.removeConfig(name: name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let name = configToDelete {
                Text("Are you sure you want to delete '\(name)'? This will stop the runner and remove the config file.")
            }
        }
    }

    // MARK: - Sidebar

    /// Sidebar listing all runner configurations with status indicators,
    /// enabled toggles, and a bottom toolbar for adding new configs.
    private var sidebar: some View {
        List(selection: $store.selectedConfigName) {
            ForEach(store.instances) { instance in
                sidebarRow(instance)
                    .tag(instance.name)
                    .contextMenu {
                        contextMenu(for: instance)
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Configurations")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Divider()
                HStack {
                    Button {
                        openWindow(id: AppConstants.WindowID.wizard)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("New Config", systemImage: AppConstants.SFSymbol.add)
                    }
                    Spacer()
                    // "Stop All" button only visible when at least one runner is active
                    if store.instances.contains(where: { $0.manager.state == .running }) {
                        Button("Stop All") {
                            Task { await store.stopAll() }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    /// A single sidebar row showing: colored status dot, config name,
    /// state label, and an enabled/disabled toggle switch.
    private func sidebarRow(_ instance: RunnerInstance) -> some View {
        HStack {
            Circle()
                .fill(statusColor(for: instance))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(instance.manager.state.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // Toggle switch for enabling/disabling auto-start. When toggled off,
            // the runner is stopped and won't auto-start on next app launch.
            Toggle("", isOn: Binding(
                get: { instance.enabled },
                set: { _ in store.toggleEnabled(name: instance.name) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    /// Right-click context menu for a sidebar row. Shows Start/Stop based
    /// on current state, plus a Delete option with confirmation.
    @ViewBuilder
    private func contextMenu(for instance: RunnerInstance) -> some View {
        switch instance.manager.state {
        case .idle, .error:
            Button("Start") { instance.manager.start() }
        case .running, .starting:
            Button("Stop") { instance.manager.stop() }
        case .stopping:
            EmptyView()
        }
        Divider()
        Button("Delete...", role: .destructive) {
            configToDelete = instance.name
            showDeleteConfirmation = true
        }
    }

    /// Maps a runner instance to a status indicator color.
    /// Disabled instances always show gray regardless of runner state.
    private func statusColor(for instance: RunnerInstance) -> Color {
        if !instance.enabled { return .gray }
        switch instance.manager.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }

    // MARK: - Detail Pane

    /// Shows either the config detail (when a config is selected) or
    /// an empty state with a "New Configuration" button.
    @ViewBuilder
    private var detail: some View {
        if let instance = store.selectedInstance {
            configDetail(instance)
        } else {
            emptyState
        }
    }

    /// Detail pane for a selected config: header bar with name and
    /// start/stop controls, error banner (if any), and the tabbed
    /// config editor with embedded log viewer.
    private func configDetail(_ instance: RunnerInstance) -> some View {
        ConfigDetailView(instance: instance)
    }

    /// A compact status badge showing a colored dot and state label.
    /// Used in the sidebar and detail pane header.
    private func statusBadge(_ instance: RunnerInstance) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: instance))
                .frame(width: 8, height: 8)
            Text(instance.manager.state.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Empty state shown when no config is selected in the sidebar.
    /// Provides a prominent "New Configuration" button as a call to action.
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: AppConstants.SFSymbol.emptyState)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select a configuration from the sidebar")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("or create a new one")
                .foregroundColor(.secondary)
            Button {
                openWindow(id: AppConstants.WindowID.wizard)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("New Configuration", systemImage: AppConstants.SFSymbol.add)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Detail pane for a selected runner configuration, showing the header bar
/// (name, status badge, start/stop), the time-series metrics graph, an error
/// banner, and the tabbed config editor with embedded log viewer.
///
/// ## Why this is a separate struct
///
/// SwiftUI does not deeply observe nested `ObservableObject` instances. The
/// `RunnerStore` publishes changes when a runner's *state* changes (via the
/// `onStateChange` closure), but high-frequency updates like `metricsHistory`
/// on `RunnerManager` would not trigger a SwiftUI re-render through the store.
///
/// By extracting `ConfigDetailView` as its own struct with a direct
/// `@ObservedObject var manager` binding, SwiftUI subscribes to *all*
/// `@Published` properties on `RunnerManager` -- including `metricsHistory`,
/// `runnerCPUPercent`, `runnerMemoryBytes`, and `lastError` -- ensuring the
/// time-series charts and error banners update in real time.
struct ConfigDetailView: View {
    /// The runner instance (provides `name`, `enabled`, and access to `logStore`).
    let instance: RunnerInstance

    /// Direct observation of the runner's manager so that high-frequency
    /// published properties (metrics, errors) trigger view updates.
    @ObservedObject var manager: RunnerManager

    /// Initializes the detail view and wires up `@ObservedObject` to the
    /// instance's manager.
    ///
    /// - Parameter instance: The runner instance to display.
    init(instance: RunnerInstance) {
        self.instance = instance
        self.manager = instance.manager
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with config name and start/stop button
            HStack {
                Text(instance.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                statusBadge

                switch manager.state {
                case .idle, .error:
                    Button("Start") { manager.start() }
                        .buttonStyle(.borderedProminent)
                case .running, .starting:
                    Button("Stop") { manager.stop() }
                        .buttonStyle(.bordered)
                case .stopping:
                    Text("Stopping...")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Time-series CPU/memory graph — only shown when runner is active
            // and has collected some history.
            if manager.state == .running,
               !manager.metricsHistory.isEmpty {
                MetricsTimeSeriesView(history: manager.metricsHistory)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            // Error banner — shown when the runner has a last error
            if let err = manager.lastError {
                HStack {
                    Image(systemName: AppConstants.SFSymbol.warning)
                        .foregroundColor(.red)
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

            Divider()

            // Tabbed config editor (includes logs as the last tab).
            // The .id() forces SwiftUI to recreate the editor when the
            // selected config changes, ensuring loadConfig() fires fresh.
            ConfigEditorView(runner: manager)
                .environmentObject(instance.logStore)
                .id(manager.configPath)
        }
    }

    /// A compact status badge showing a colored dot and state label.
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(manager.state.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        if !instance.enabled { return .gray }
        switch manager.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }
}
