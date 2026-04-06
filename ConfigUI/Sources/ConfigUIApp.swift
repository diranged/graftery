import SwiftUI

/// App delegate that owns the RunnerStore and StatusBarController.
///
/// These must live here (not in the SwiftUI App struct) because:
/// 1. `@StateObject` in a struct creates a new instance on each `init` call,
///    so long-lived objects like the process manager would be recreated.
/// 2. `StatusBarController` setup needs to happen exactly once, without a visible window.
/// 3. The delegate is guaranteed to be a single long-lived `NSObject` instance
///    managed by AppKit, not by SwiftUI's value-type lifecycle.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let store = RunnerStore()
    let statusBar = StatusBarController()
    let banner = LaunchBanner()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Suppress macOS window restoration. SwiftUI creates and shows the first
        // Window scene during launch — we need to prevent this for a menu-bar-only
        // app (LSUIElement = true). There is no AppKit constant for this key;
        // it is a documented NSUserDefaults key in Apple's Window Restoration docs.
        UserDefaults.standard.set(false, forKey: AppConstants.UserDefaultsKeys.quitAlwaysKeepsWindows)
    }

    /// Stored reference to the SwiftUI `openWindow` action, bridged from the
    /// App struct via closure capture. This allows AppKit code (notifications
    /// from StatusBarController) to open SwiftUI-managed Window scenes.
    var openWindowAction: ((String) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        banner.show()

        // Hide any windows SwiftUI eagerly created during launch. We keep our
        // launch banner panel (an NSPanel subclass) visible — the `is NSPanel`
        // check distinguishes it from SwiftUI's auto-created NSWindows.
        for window in NSApp.windows where !(window is NSPanel) {
            window.orderOut(nil)
        }

        // Listen for window-open requests posted by StatusBarController.
        // StatusBarController lives in AppKit and cannot hold an
        // @Environment(\.openWindow) reference, so it posts a notification
        // with the window ID as the object. We forward it to the SwiftUI
        // openWindow action captured from the App struct.
        NotificationCenter.default.addObserver(
            forName: AppConstants.Notifications.openWindowRequest,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let id = notification.object as? String {
                self?.openWindowAction?(id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        // Delay StatusBarController setup until after RunnerStore.loadAll()
        // has finished scanning configs and checking for tart. The 1.5s delay
        // accounts for the 1.0s delay in RunnerStore.init before loadAll() fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            statusBar.setup(store: store)
        }
    }
}

/// The main app entry point.
///
/// Graftery is a **menu-bar-only app** (`LSUIElement = true` in Info.plist)
/// that manages multiple Go CLI subprocesses, each with its own YAML configuration
/// file. All user interaction happens through the menu bar dropdown and secondary
/// windows (configurations, wizard, about).
///
/// Architecture note: We use an invisible `MenuBarExtra` to prevent SwiftUI from
/// auto-opening Window scenes on launch. The *real* menu bar icon is managed by
/// `StatusBarController` via AppKit, because `MenuBarExtra` does not support
/// colored attributed strings or custom NSView items in its menu.
@main
struct GrafteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Convenience accessor so views don't need to reach through appDelegate.
    private var store: RunnerStore { appDelegate.store }

    var body: some Scene {
        // Wire up the openWindow bridge on every body evaluation. This is safe
        // because `body` is re-evaluated frequently by SwiftUI and the closure
        // merely captures the current `openWindow` environment value. The
        // alternative (storing openWindow in onAppear) breaks because onAppear
        // only fires once per view lifecycle and openWindow can change.
        let _ = {
            appDelegate.openWindowAction = { [self] id in
                openWindow(id: id)
            }
        }()

        // Invisible MenuBarExtra — its sole purpose is to prevent SwiftUI from
        // auto-opening the first Window scene on launch. Without this, SwiftUI
        // assumes the app has no menu bar presence and shows a window instead.
        // Our real menu bar icon is managed by StatusBarController (AppKit).
        MenuBarExtra(AppConstants.appName, isInserted: .constant(false)) {
            EmptyView()
        }

        // Unified configuration window: sidebar listing all configs + detail
        // pane with tabbed editor and embedded log viewer.
        Window("Graftery — Configurations", id: AppConstants.WindowID.configurations) {
            ConfigurationsView(store: store)
        }
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)

        // Setup wizard: step-by-step flow that creates a new named configuration.
        // The onComplete callback adds the config to the store and auto-starts
        // the runner (unless tart is missing).
        Window("Graftery Setup", id: AppConstants.WindowID.wizard) {
            WizardView(onComplete: { name in
                store.addConfig(name: name)
                store.needsFirstRunWizard = false
                store.selectedConfigName = name
                if let instance = store.instance(named: name) {
                    if !store.tartMissing {
                        instance.manager.start()
                    }
                }
            })
            .frame(minWidth: 600, minHeight: 500)
        }
        .defaultSize(width: 680, height: 640)
        .windowResizability(.contentMinSize)

        // About window: app-level info (version, links), not per-configuration.
        Window("About Graftery", id: AppConstants.WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    @Environment(\.openWindow) private var openWindow
}
