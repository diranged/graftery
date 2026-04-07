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

/// Pure AppKit view that draws two tiny vertical bar gauges side by side,
/// representing CPU and memory usage in an iStat Menus-inspired style.
///
/// This view is used in two places:
/// 1. **Menu bar status item** -- embedded in the `NSStatusItem` button next to the app icon.
/// 2. **Dropdown menu items** -- each per-config `ConfigMenuItemView` contains its own gauge.
///
/// We use CoreGraphics drawing (via `NSBezierPath`) rather than SwiftUI because
/// `NSStatusItem` buttons do not reliably host live SwiftUI `NSHostingView` subviews.
/// AppKit drawing is guaranteed to render correctly in the menu bar's compositing context.
///
/// ## Drawing layout
///
/// The view draws two rounded-rect bars centered horizontally within its bounds:
/// ```
///  ┌──────────────┐
///  │  ┌──┐ ┌──┐   │  <- 1px top padding
///  │  │CP│ │Me│   │
///  │  │U │ │m │   │
///  │  │  │ │  │   │
///  │  └──┘ └──┘   │  <- 1px bottom padding
///  └──────────────┘
/// ```
/// Each bar has a translucent "track" background (always visible, even at 0%) and a
/// filled portion that grows from the bottom up based on the percentage value.
///
/// CPU is drawn in system green; memory is drawn in system cyan.
class MiniBarGaugeView: NSView {

    /// CPU usage percentage (0--100). Values outside this range are clamped during drawing.
    /// Setting this property automatically triggers a redraw via `needsDisplay`.
    var cpuPercent: Double = 0 { didSet { needsDisplay = true } }

    /// Memory usage percentage (0--100). Values outside this range are clamped during drawing.
    /// Setting this property automatically triggers a redraw via `needsDisplay`.
    var memoryPercent: Double = 0 { didSet { needsDisplay = true } }

    /// Width of each individual bar in points.
    private let barWidth: CGFloat = 6

    /// Horizontal gap between the CPU bar and the memory bar, in points.
    private let barGap: CGFloat = 2

    /// Corner radius applied to each bar's rounded rectangle.
    private let barRadius: CGFloat = 1.5

    /// Returns the intrinsic size: two bars plus the gap horizontally, and 14pt vertically.
    /// Auto Layout uses this when no explicit width/height constraints are set.
    override var intrinsicContentSize: NSSize {
        NSSize(width: barWidth * 2 + barGap, height: 14)
    }

    /// Draws the gauge bars using CoreGraphics.
    ///
    /// The drawing proceeds in two passes:
    /// 1. **Track pass** -- draws translucent background rectangles for both bars so the
    ///    gauge shape is visible even when values are at 0%.
    /// 2. **Fill pass** -- draws opaque colored rectangles whose height is proportional
    ///    to the clamped percentage value (0--100%). Bars grow upward from the bottom.
    ///
    /// A 1px vertical padding is applied at the top and bottom so the bars don't touch
    /// the view edges, which looks better in the tight menu bar layout.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Usable height after subtracting 1px padding on each side.
        let height = bounds.height - 2
        let y: CGFloat = 1  // Bottom padding offset.

        // Center the two bars horizontally within the view bounds.
        let cpuX = (bounds.width - (barWidth * 2 + barGap)) / 2
        let memX = cpuX + barWidth + barGap

        // --- Track pass: translucent backgrounds (always drawn) ---
        let trackColor = NSColor.labelColor.withAlphaComponent(0.25)
        trackColor.setFill()
        let cpuTrack = NSBezierPath(roundedRect: NSRect(x: cpuX, y: y, width: barWidth, height: height), xRadius: barRadius, yRadius: barRadius)
        cpuTrack.fill()
        let memTrack = NSBezierPath(roundedRect: NSRect(x: memX, y: y, width: barWidth, height: height), xRadius: barRadius, yRadius: barRadius)
        memTrack.fill()

        // --- Fill pass: colored bars proportional to the percentage ---
        let cpuFill = height * CGFloat(min(max(cpuPercent, 0), 100)) / 100
        let memFill = height * CGFloat(min(max(memoryPercent, 0), 100)) / 100

        if cpuFill > 0 {
            NSColor.systemGreen.setFill()
            let cpuBar = NSBezierPath(roundedRect: NSRect(x: cpuX, y: y, width: barWidth, height: cpuFill), xRadius: barRadius, yRadius: barRadius)
            cpuBar.fill()
        }

        if memFill > 0 {
            NSColor.systemCyan.setFill()
            let memBar = NSBezierPath(roundedRect: NSRect(x: memX, y: y, width: barWidth, height: memFill), xRadius: barRadius, yRadius: barRadius)
            memBar.fill()
        }
    }
}
