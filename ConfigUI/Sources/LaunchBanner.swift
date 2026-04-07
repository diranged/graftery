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

import AppKit
import SwiftUI

/// Shows a brief floating banner on app launch that animates up toward the
/// menu bar icon and fades out.
///
/// Uses `NSPanel` (not `NSWindow`) because:
/// 1. `NSPanel` with `.nonactivatingPanel` style doesn't steal focus or
///    activate the app — critical for `LSUIElement` menu bar apps where
///    activation would show an unexpected Dock icon.
/// 2. The panel is excluded from the `NSApp.windows` filter in
///    `applicationDidFinishLaunching` (which hides SwiftUI's auto-created
///    windows) because we check `!(window is NSPanel)`.
class LaunchBanner {
    private var panel: NSPanel?

    /// Shows the banner centered horizontally in the upper portion of the screen.
    /// After `StatusBarController` has created the NSStatusItem (at ~1.5s),
    /// the banner animates toward the menu bar icon and fades out.
    func show() {
        let content = NSHostingView(rootView: BannerContent())
        content.frame = NSRect(
            x: 0, y: 0,
            width: AppConstants.bannerWidth,
            height: AppConstants.bannerHeight
        )

        let panel = NSPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: AppConstants.bannerWidth,
                height: AppConstants.bannerHeight
            ),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isFloatingPanel = true
        // `.floating` level keeps the banner above regular windows but below
        // alerts and the menu bar, which is the right visual hierarchy.
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Don't hide when the app deactivates — the banner should remain
        // visible even if the user clicks on another app during startup.
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        // Position: centered horizontally, upper third of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - (AppConstants.bannerWidth / 2)
            let y = screenFrame.maxY - 200
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        // Animate after StatusBarController has created the NSStatusItem.
        // StatusBarController.setup() runs at 1.5s, so we wait 2.0s to ensure
        // the status bar window exists as our animation target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.animateToMenuBar()
        }
    }

    /// Animates the panel shrinking and moving toward the actual menu bar
    /// status item, then removes it. The animation targets the real status
    /// bar window (found by class name) so the banner appears to "dock" into
    /// the menu bar icon.
    private func animateToMenuBar() {
        guard let panel, let screen = NSScreen.main else { return }

        // Default target rect: upper-right corner of the screen (fallback
        // if we can't find the status bar window).
        var targetRect = NSRect(
            x: screen.frame.maxX - 100,
            y: screen.frame.maxY - 30,
            width: 40,
            height: 10
        )

        // Search for the NSStatusBarWindow that contains our menu bar icon.
        // We match by class name because AppKit doesn't expose a public API
        // to get the status item's window. Only visible windows are checked
        // to skip the invisible MenuBarExtra's hidden status bar window.
        for window in NSApp.windows where window.isVisible {
            let className = String(describing: type(of: window))
            if className.contains("StatusBar") {
                let frame = window.frame
                targetRect = NSRect(
                    x: frame.midX - 20,
                    y: frame.midY - 5,
                    width: 40,
                    height: 10
                )
                break
            }
        }

        // Animate: shrink the panel to the target rect while fading to transparent.
        // `.easeIn` timing makes the motion accelerate, giving a "sucked in" feel.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetRect, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel = nil
        })
    }
}

/// The visual content of the launch banner — app icon, name, and "Starting up..." text.
/// Rendered as a SwiftUI view hosted inside the NSPanel via `NSHostingView`.
private struct BannerContent: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AppConstants.SFSymbol.appIconFilled)
                .font(.system(size: 36))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text(AppConstants.appName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text("Starting up...")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: AppConstants.bannerWidth, height: AppConstants.bannerHeight)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }
}
