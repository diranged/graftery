import AppKit
import SwiftUI

/// Manages the NSStatusItem (menu bar icon) and its dropdown NSMenu via AppKit.
///
/// We bypass SwiftUI's `MenuBarExtra` because it does not support:
/// - Colored attributed strings in menu items (e.g., green "running", red "error")
/// - Custom NSView menu items (needed so start/stop clicks don't dismiss the menu)
/// - Right-aligned content in the menu
///
/// This gives us the same capabilities as macOS system menus (Wi-Fi, Bluetooth)
/// where text can be colored and interactive controls stay in the menu.
///
/// If Apple adds attributed string support to `MenuBarExtra` in a future macOS
/// release, this class could potentially be replaced — but the custom-view
/// requirement for non-dismissing actions would still need AppKit.
@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    weak var store: RunnerStore?
    private var refreshTimer: Timer?
    private var menuIsOpen = false

    /// Timer that periodically aggregates runner metrics and pushes them to the
    /// menu bar gauge. Runs in `.common` mode so updates continue even when the
    /// menu is open (event-tracking run loop mode). Fires at `menuRefreshInterval`.
    private var metricsTimer: Timer?

    /// The pure AppKit bar gauge view (`MiniBarGaugeView`) embedded inside the
    /// `NSStatusItem` button, positioned to the right of the app icon. Displays
    /// aggregated CPU and memory usage across all running configurations.
    private var barGaugeView: MiniBarGaugeView?

    /// Creates the NSStatusItem and wires up click handling. Must be called
    /// after RunnerStore.loadAll() has finished so the menu can accurately
    /// reflect the current state of all configurations.
    ///
    /// - Parameter store: The shared RunnerStore that owns all runner instances.
    func setup(store: RunnerStore) {
        self.store = store

        // Fixed width: icon (~18px) + gap + gauge (~16px) + padding.
        let item = NSStatusBar.system.statusItem(withLength: 46)

        if let button = item.button {
            // SF Symbol icon on the left via the button's built-in image.
            button.image = NSImage(
                systemSymbolName: AppConstants.SFSymbol.appIcon,
                accessibilityDescription: AppConstants.appName
            )
            button.imagePosition = .imageLeft

            // Pure AppKit bar gauge view on the right.
            let gauge = MiniBarGaugeView()
            gauge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(gauge)
            NSLayoutConstraint.activate([
                gauge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
                gauge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                gauge.widthAnchor.constraint(equalToConstant: 14),
                gauge.heightAnchor.constraint(equalToConstant: 14),
            ])
            barGaugeView = gauge

            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp])
        }
        self.statusItem = item

        // Start a timer to update the menu bar chart from runner metrics.
        let timer = Timer(timeInterval: AppConstants.menuRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuBarMetrics()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        metricsTimer = timer

        // If no configs exist, open the wizard automatically so first-time
        // users aren't left staring at an empty menu.
        if store.needsFirstRunWizard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openWindow(AppConstants.WindowID.wizard)
            }
        }
    }

    /// Aggregates CPU and memory metrics across all running configurations and
    /// updates the menu bar gauge view with the latest values.
    ///
    /// CPU is normalized from per-core percentages (gopsutil reports e.g. 300%
    /// for 3 fully-loaded cores) down to a 0--100% scale representing total
    /// host capacity. Memory is expressed as a percentage of total host RAM.
    /// The gauge tooltip shows both raw and normalized values for debugging.
    private func updateMenuBarMetrics() {
        guard let store else { return }
        var totalCPU: Double = 0
        var totalMem: UInt64 = 0
        var hostMemTotal: UInt64 = 0
        var cpuCount: Int = 1
        for instance in store.instances where instance.manager.state == .running {
            totalCPU += instance.manager.runnerCPUPercent
            totalMem += instance.manager.runnerMemoryBytes
            if instance.manager.hostMemoryTotal > hostMemTotal {
                hostMemTotal = instance.manager.hostMemoryTotal
            }
            if instance.manager.hostCPUCount > cpuCount {
                cpuCount = instance.manager.hostCPUCount
            }
        }
        // Normalize CPU: gopsutil reports per-core (e.g., 300% = 3 cores).
        // Divide by core count to get 0-100% of total host capacity.
        let cpuNormalized = totalCPU / Double(cpuCount)
        let memPct = hostMemTotal > 0
            ? Double(totalMem) / Double(hostMemTotal) * 100
            : 0
        barGaugeView?.cpuPercent = cpuNormalized
        barGaugeView?.memoryPercent = memPct
        barGaugeView?.toolTip = String(
            format: "Runners: CPU %.1f%% (%.1f%% raw) | Mem %@ / %@",
            cpuNormalized,
            totalCPU,
            formatBytes(totalMem),
            formatBytes(hostMemTotal)
        )
    }

    // MARK: - NSMenuDelegate

    /// Called by AppKit when the menu is about to appear. Starts a 1-second
    /// refresh timer so state transitions (starting -> running, stopping -> idle)
    /// are visible to the user without closing and reopening the menu.
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            self.menuIsOpen = true
            // Timer in `.common` mode fires even during event-tracking (when
            // the menu is open and the run loop is in tracking mode).
            let timer = Timer(timeInterval: AppConstants.menuRefreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateConfigItemsInPlace()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.refreshTimer = timer
        }
    }

    /// Called by AppKit when the menu has closed. Stops the refresh timer
    /// and clears the menu so the next click rebuilds it from scratch
    /// (ensuring any added/removed configs are reflected).
    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in
            self.menuIsOpen = false
            self.refreshTimer?.invalidate()
            self.refreshTimer = nil
            self.statusItem?.menu = nil
        }
    }

    /// Updates config menu items in place without rebuilding the entire menu.
    /// This preserves the menu's open state and avoids visual flicker. Each
    /// config item is found by its tag (hash of the config name) and its
    /// custom NSView is told to refresh its labels.
    private func updateConfigItemsInPlace() {
        guard let menu = statusItem?.menu, let store else { return }
        for instance in store.instances {
            let tag = instance.name.hashValue
            guard let item = menu.items.first(where: { $0.tag == tag }),
                  let view = item.view as? ConfigMenuItemView else { continue }
            view.update()
        }
    }

    /// Returns the screen frame of the status item button. Used by
    /// `LaunchBanner` to animate toward the menu bar icon's position.
    var buttonFrame: NSRect? {
        statusItem?.button?.window?.frame
    }

    /// Handles a left-click on the status item by building a fresh menu
    /// and presenting it via performClick. We build on-click (not in advance)
    /// because the menu content depends on dynamic state (runner count, tart
    /// availability, running status).
    @objc private func statusItemClicked() {
        guard let store, let button = statusItem?.button else { return }
        let menu = buildMenu()
        menu.delegate = self
        statusItem?.menu = menu
        button.performClick(nil)
    }

    /// Constructs the full dropdown menu from scratch. Called on each click
    /// because runner state, config list, and tart availability can all change
    /// between clicks.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Header: app name and version (disabled = non-clickable)
        let header = NSMenuItem(
            title: "\(AppConstants.appName) v\(AppConstants.appVersion)",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        guard let store else { return menu }

        // Tart-missing warning block: shown when tart cannot be found in
        // PATH or common install locations. Provides recheck and manual
        // locate actions so the user doesn't have to quit and restart.
        if store.tartMissing {
            let warning = NSMenuItem(title: "⚠ Tart not found", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)

            let hint = NSMenuItem(title: "  brew install cirruslabs/cli/tart", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)

            let recheck = NSMenuItem(title: "Re-check for Tart", action: #selector(recheckTart), keyEquivalent: "")
            recheck.target = self
            menu.addItem(recheck)

            let locate = NSMenuItem(title: "Locate Tart...", action: #selector(locateTart), keyEquivalent: "")
            locate.target = self
            menu.addItem(locate)

            menu.addItem(.separator())
        }

        // Per-config items: each gets a custom NSView so clicking start/stop
        // does not dismiss the menu (standard NSMenuItem actions always dismiss).
        if store.instances.isEmpty {
            let empty = NSMenuItem(title: "No configurations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for instance in store.instances {
                let item = buildConfigMenuItem(instance)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // New Configuration: opens the setup wizard.
        let newConfig = NSMenuItem(title: "New Configuration...", action: #selector(newConfiguration), keyEquivalent: "n")
        newConfig.target = self
        menu.addItem(newConfig)

        // Manage Configurations: opens the sidebar + editor window.
        let manage = NSMenuItem(title: "Manage Configurations...", action: #selector(manageConfigurations), keyEquivalent: ",")
        manage.target = self
        menu.addItem(manage)

        menu.addItem(.separator())

        // About: version info and project links.
        let about = NSMenuItem(title: "About Graftery...", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        // Stop All: only shown when at least one runner is active.
        if store.instances.contains(where: { $0.manager.state == .running }) {
            let stopAll = NSMenuItem(title: "Stop All", action: #selector(stopAllRunners), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }

        // Quit: stops all runners gracefully before terminating.
        let quit = NSMenuItem(title: "Quit Graftery", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Computes the display attributes for a config's menu item: the attributed
    /// title string, the action button icon (play/stop/waiting), and the
    /// selector to invoke when the button is clicked.
    ///
    /// This is separated from `buildConfigMenuItem` so the same logic can be
    /// used by both the initial build and the in-place refresh.
    private func configMenuItemContent(_ instance: RunnerInstance) -> (NSAttributedString, String, Selector) {
        let statusText: String
        let statusColor: NSColor
        let icon: String
        let actionSelector: Selector

        if !instance.enabled {
            statusText = AppConstants.MenuStatus.disabled
            statusColor = .secondaryLabelColor
            icon = AppConstants.MenuIcon.play
            actionSelector = #selector(toggleConfig(_:))
        } else {
            switch instance.manager.state {
            case .idle:
                statusText = AppConstants.MenuStatus.stopped
                statusColor = .secondaryLabelColor
                icon = AppConstants.MenuIcon.play
                actionSelector = #selector(startConfig(_:))
            case .error:
                statusText = AppConstants.MenuStatus.error
                statusColor = .systemRed
                icon = AppConstants.MenuIcon.play
                actionSelector = #selector(startConfig(_:))
            case .running:
                statusText = AppConstants.MenuStatus.running
                statusColor = .systemGreen
                icon = AppConstants.MenuIcon.stop
                actionSelector = #selector(stopConfig(_:))
            case .starting:
                statusText = AppConstants.MenuStatus.starting
                statusColor = .systemOrange
                icon = AppConstants.MenuIcon.stop
                actionSelector = #selector(stopConfig(_:))
            case .stopping:
                statusText = AppConstants.MenuStatus.stopping
                statusColor = .systemOrange
                icon = AppConstants.MenuIcon.waiting
                actionSelector = #selector(doNothing)
            }
        }

        let str = NSMutableAttributedString()
        str.append(NSAttributedString(string: "\(instance.name): ", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        str.append(NSAttributedString(string: statusText, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: statusColor,
        ]))

        return (str, icon, actionSelector)
    }

    /// Builds a config menu item using a custom NSView. Standard NSMenuItem
    /// actions always dismiss the menu on click — using a custom view with
    /// its own button avoids this, so the user can start/stop runners without
    /// the menu closing each time.
    private func buildConfigMenuItem(_ instance: RunnerInstance) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = instance.name.hashValue
        item.representedObject = instance.name

        let view = ConfigMenuItemView(instance: instance, controller: self)
        item.view = view
        return item
    }

    // MARK: - Actions

    /// Starts the runner for the config identified by the menu item's representedObject.
    @objc private func startConfig(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let instance = store?.instance(named: name) else { return }
        instance.manager.start()
    }

    /// Stops the runner for the config identified by the menu item's representedObject.
    @objc private func stopConfig(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let instance = store?.instance(named: name) else { return }
        instance.manager.stop()
    }

    /// Toggles enabled/disabled state for a config (re-enables a disabled runner).
    @objc private func toggleConfig(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        store?.toggleEnabled(name: name)
    }

    /// Re-scans PATH and common locations for tart. If found, auto-starts
    /// all enabled configs.
    @objc private func recheckTart() {
        if store?.checkTartAvailable() == true {
            store?.startAllEnabled()
        }
    }

    /// Opens a file picker for the user to manually locate the tart binary.
    /// Useful when tart is installed in a non-standard location not covered
    /// by our search paths.
    @objc private func locateTart() {
        let panel = NSOpenPanel()
        panel.title = "Locate the tart binary"
        panel.message = "Select the tart executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store?.saveTartPathToAllConfigs(url.path)
            store?.startAllEnabled()
        }
    }

    /// Opens the setup wizard window for creating a new configuration.
    @objc private func newConfiguration() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(AppConstants.WindowID.wizard)
    }

    /// Opens the main configurations management window.
    @objc private func manageConfigurations() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(AppConstants.WindowID.configurations)
    }

    /// Opens the About window.
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(AppConstants.WindowID.about)
    }

    /// Stops all running instances asynchronously.
    @objc private func stopAllRunners() {
        Task { await store?.stopAll() }
    }

    /// Gracefully stops all runners and then terminates the application.
    @objc private func quitApp() {
        Task {
            await store?.stopAll()
            NSApp.terminate(nil)
        }
    }

    /// No-op selector used for menu items in the "stopping" state where
    /// no action should be taken (the stop is already in progress).
    @objc private func doNothing() {}

    /// Opens a SwiftUI Window scene by its ID. First checks if the window
    /// already exists (SwiftUI creates NSWindows with identifiers containing
    /// the scene ID), and if so brings it to front. Otherwise posts a
    /// notification that the App struct's observer forwards to `openWindow`.
    ///
    /// This two-step approach is necessary because:
    /// 1. SwiftUI lazily creates windows, so on first open the NSWindow doesn't exist yet
    /// 2. StatusBarController (AppKit) cannot hold @Environment(\.openWindow)
    private func openWindow(_ id: String) {
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(id) == true
        }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NotificationCenter.default.post(
                name: AppConstants.Notifications.openWindowRequest,
                object: id
            )
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Notification Name Extension

extension Notification.Name {
    /// Posted by StatusBarController when it needs to open a SwiftUI Window scene.
    /// The notification's `object` is the window ID string (e.g., "configurations").
    static let openWindowRequest = AppConstants.Notifications.openWindowRequest
}

// MARK: - ConfigMenuItemView

/// Custom NSView used as the content of each per-config NSMenuItem.
///
/// Using a custom view instead of a standard NSMenuItem action prevents the
/// menu from closing when the user clicks the start/stop button. Standard
/// NSMenuItem actions always dismiss the menu — this is an AppKit limitation
/// with no workaround except custom views.
///
/// The view is updated every second by the `StatusBarController`'s refresh timer
/// while the menu is open, so state transitions are visible in real time.
class ConfigMenuItemView: NSView {
    private weak var instance: RunnerInstance?
    private weak var controller: StatusBarController?
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    /// Per-config mini bar gauge showing CPU and memory for this configuration's
    /// runners. Hidden when the runner is not active or has no VM metrics yet.
    /// Updated every refresh cycle by `update()`.
    private var gaugeView: MiniBarGaugeView?
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    init(instance: RunnerInstance, controller: StatusBarController) {
        self.instance = instance
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 22))

        // Name label — shows the config name followed by a colon.
        nameLabel.font = NSFont.menuFont(ofSize: 0)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        // Status label — shows colored state text (running/stopped/error/etc).
        statusLabel.font = NSFont.menuFont(ofSize: 0)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Mini bar gauge — shows per-config CPU/memory to the right of status.
        let gauge = MiniBarGaugeView()
        gauge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gauge)
        gaugeView = gauge

        // Action button — Unicode play/stop icon. Uses a plain text button
        // rather than SF Symbols because NSMenu custom views render more
        // reliably with simple text at menu-item sizes.
        actionButton.isBordered = false
        actionButton.font = NSFont.systemFont(ofSize: AppConstants.menuItemButtonFontSize)
        actionButton.target = self
        actionButton.action = #selector(buttonClicked)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 4),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            gauge.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),
            gauge.centerYAnchor.constraint(equalTo: centerYAnchor),
            gauge.widthAnchor.constraint(equalToConstant: 14),
            gauge.heightAnchor.constraint(equalToConstant: 14),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Installs a tracking area so we get mouseEntered/mouseExited events
    /// for hover highlighting. Must be recreated when the view's bounds change.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        needsDisplay = true
    }

    /// Draws the highlight background when the mouse hovers over this item,
    /// matching the standard NSMenuItem highlight appearance.
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
            nameLabel.textColor = .white
        } else {
            nameLabel.textColor = .labelColor
        }
    }

    /// Refreshes the labels and action button to reflect the current runner state.
    /// Called by the menu refresh timer every second while the menu is open.
    func update() {
        guard let instance else { return }

        nameLabel.stringValue = "\(instance.name):"

        let statusText: String
        let statusColor: NSColor
        let icon: String

        if !instance.enabled {
            statusText = AppConstants.MenuStatus.disabled
            statusColor = .secondaryLabelColor
            icon = AppConstants.MenuIcon.play
        } else {
            switch instance.manager.state {
            case .idle:
                statusText = AppConstants.MenuStatus.stopped
                statusColor = .secondaryLabelColor
                icon = AppConstants.MenuIcon.play
            case .error:
                statusText = AppConstants.MenuStatus.error
                statusColor = .systemRed
                icon = AppConstants.MenuIcon.play
            case .running:
                statusText = AppConstants.MenuStatus.running
                statusColor = .systemGreen
                icon = AppConstants.MenuIcon.stop
            case .starting:
                statusText = AppConstants.MenuStatus.starting
                statusColor = .systemOrange
                icon = AppConstants.MenuIcon.stop
            case .stopping:
                statusText = AppConstants.MenuStatus.stopping
                statusColor = .systemOrange
                icon = AppConstants.MenuIcon.waiting
            }
        }

        statusLabel.stringValue = statusText
        statusLabel.textColor = statusColor
        actionButton.title = icon

        // Update the per-config mini gauge with latest runner metrics.
        let cpuRaw = instance.manager.runnerCPUPercent
        let cpuCount = max(instance.manager.hostCPUCount, 1)
        let cpuNorm = cpuRaw / Double(cpuCount)
        let mem = instance.manager.runnerMemoryBytes
        let hostMemTotal = instance.manager.hostMemoryTotal
        gaugeView?.cpuPercent = cpuNorm
        gaugeView?.memoryPercent = hostMemTotal > 0
            ? Double(mem) / Double(hostMemTotal) * 100
            : 0
        gaugeView?.toolTip = String(
            format: "CPU %.1f%% (%.0f%% raw / %d cores) | Mem %@ / %@",
            cpuNorm, cpuRaw, cpuCount,
            formatBytes(mem), formatBytes(hostMemTotal)
        )
        // Only show the gauge when the runner is active and has VMs.
        gaugeView?.isHidden = instance.manager.state != .running
            || (cpuRaw == 0 && mem == 0)
    }

    /// Handles a click on the action button. Dispatches to the appropriate
    /// store/manager action based on the current runner state. Schedules
    /// a delayed UI refresh so the state change is immediately visible
    /// without waiting for the next timer tick.
    @objc private func buttonClicked() {
        guard let instance, let controller else { return }
        if !instance.enabled {
            controller.store?.toggleEnabled(name: instance.name)
        } else {
            switch instance.manager.state {
            case .idle, .error:
                instance.manager.start()
            case .running, .starting:
                instance.manager.stop()
            case .stopping:
                break
            }
        }
        // Update immediately without waiting for the 1-second timer tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.update()
        }
    }
}

// MARK: - Helpers

/// Formats a byte count into a human-readable string (e.g., "4.2 GB", "512 MB").
///
/// Uses binary units (1 GB = 1024^3 bytes). Values >= 1 GB are shown with one
/// decimal place; smaller values are shown in whole megabytes. Defined at file
/// scope so it can be used by both `StatusBarController` and `ConfigMenuItemView`.
///
/// - Parameter bytes: The byte count to format.
/// - Returns: A compact human-readable string like "4.2 GB" or "512 MB".
private func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1 {
        return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / (1024 * 1024)
    return String(format: "%.0f MB", mb)
}
