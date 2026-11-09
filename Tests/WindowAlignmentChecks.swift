import AppKit
import SwiftUI

/// Hidden native windows exercise AppKit's actual integral-edge rounding,
/// without displaying synthetic displaced panels on the user's desktop.
@main struct WindowAlignmentChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: Color.black)
        host.sizingOptions = []; host.autoresizingMask = [.width, .height]; panel.contentView = host
        defer { panel.orderOut(nil) }
        var unalignedCenters: Set<CGFloat> = []
        for width in [393.0, 393.02, 393.4, 394.1] {
            panel.setFrame(MenuBarAvoidance.topFrame(center: 750, screenTop: 900,
                size: CGSize(width: width, height: 32.12)), display: false)
            unalignedCenters.insert(panel.frame.midX)
        }
        print("Native fractional-frame fixture: \(unalignedCenters.count) distinct horizontal centers before alignment")
        for center in [750.0, 750.5, -749.5] {
            for top in [900.0, 849.0] { // Attached top and floating top.
                let compact = MenuBarAvoidance.nativeTopFrame(MenuBarAvoidance.topFrame(center: center, screenTop: top, size: CGSize(width: 393, height: 36)))
                let expanded = MenuBarAvoidance.nativeTopFrame(MenuBarAvoidance.topFrame(center: center, screenTop: top, size: CGSize(width: 581, height: 303)))
                for (start, target) in [(expanded, compact), (compact, expanded)] {
                    for step in 0...1000 {
                        let sample = MenuBarAvoidance.frame(from: start, to: target,
                            progress: Double(step) / 1000, opening: target.height > start.height,
                            resizingContent: false, headphone: false)
                        let aligned = MenuBarAvoidance.nativeTopFrame(sample, center: target.midX, top: target.maxY)
                        panel.setFrame(aligned, display: false); host.layoutSubtreeIfNeeded()
                        precondition(panel.frame == aligned, "AppKit must not change the submitted frame")
                        precondition(panel.frame.midX == center && panel.frame.maxY == top,
                            "Every actual native frame, including the last one, must keep exactly the same anchor")
                        precondition(host.frame.size == panel.contentLayoutRect.size)
                        if step == 1000 {
                            let settled = panel.frame
                            panel.setFrame(target, display: false)
                            precondition(panel.frame == settled, "The final target must not cause a second position adjustment")
                        }
                    }
                }
            }
        }
        for center in [750.25, -749.75] {
            let frame = MenuBarAvoidance.nativeTopFrame(MenuBarAvoidance.topFrame(center: center, screenTop: 900, size: CGSize(width: 393.3, height: 36.2)))
            precondition(abs(frame.midX - center) <= 0.25)
            precondition(MenuBarAvoidance.nativeTopFrame(frame) == frame, "Repeated corrections must be idempotent")
        }
        precondition(!panel.isVisible)
        print("PASS: 12,012 hidden AppKit/SwiftUI frames retain exact top/center through expansion, collapse and final correction, for integer/half-point centers and negative screen coordinates")
    }
}
