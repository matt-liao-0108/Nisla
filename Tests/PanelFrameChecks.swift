import AppKit
import SwiftUI

/// Exercises the real native panel, with fixture storage and direct HUD
/// presentation only. No media-key interception, audio writes or permissions.
@main struct PanelFrameChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            print("SKIP: native panel checks require a WindowServer display; pure geometry and render suites still run")
            exit(77)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandPanelChecks-" + UUID().uuidString)
        let store = PinStore(storageDirectory: directory,
            preferences: UserDefaults(suiteName: "IslandPanelChecks-" + UUID().uuidString)!, interactive: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.options.appearance = "black"; store.selectedTab = 1; store.keepOpen = true
        let panel = IslandPanel(store: store, screen: screen)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); SystemHUD.shared.stop() }
        let header = max(32, screen.safeAreaInsets.top)
        let notch = screen.auxiliaryTopLeftArea.flatMap { left in screen.auxiliaryTopRightArea.map { max(0, $0.minX - left.maxX) } } ?? 0
        let hudSize = SystemHUDGeometry.size(notchWidth: notch, headerHeight: header)

        func sample(_ duration: Double) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < duration {
                precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
                precondition(panel.frame.height >= header - 0.5)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        SystemHUD.shared.present(.init(kind: .volume, value: 0.19), duration: .seconds(10))
        panel.setExpanded(false)
        try await sample(0.55)
        precondition(abs(panel.frame.width - hudSize.width) < 0.5 && abs(panel.frame.height - hudSize.height) < 0.5)
        let settled = panel.frame
        for level in [0.25, 0.31, 0.38, 0.44] {
            SystemHUD.shared.present(.init(kind: .volume, value: level), duration: .seconds(10))
            panel.setExpanded(false)
            precondition(panel.frame == settled, "Held volume keys must not restart the entrance")
        }
        SystemHUD.shared.stop(); panel.setExpanded(false)
        try await sample(0.45)
        precondition(abs(panel.frame.height - header) < 0.5)
        precondition(store.selectedTab == 1 && !store.isExpanded)

        store.isExpanded = true; panel.setExpanded(true)
        try await sample(0.95)
        let page = panel.frame
        store.isResizingWidth = true
        for width in [600.0, 740, 520, 580] {
            panel.setExpanded(true, shelfWidth: width)
            precondition(abs(panel.frame.width - width) < 0.5, "Interactive resize must apply synchronously, without debounce or animation")
            precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
        }
        store.isResizingWidth = false
        panel.setExpanded(true)
        try await sample(0.95)
        precondition(panel.frame == page)
        SystemHUD.shared.present(.init(kind: .brightness, value: 0.72), duration: .seconds(10))
        panel.setExpanded(true)
        try await sample(0.55)
        precondition(abs(panel.frame.height - hudSize.height) < 0.5)
        SystemHUD.shared.stop(); panel.setExpanded(true)
        try await sample(0.55)
        precondition(panel.frame == page && store.selectedTab == 1 && store.isExpanded)
        print("PASS: real native HUD panel grows and retracts at the top, held updates do not restart motion, original expanded page restores; fixture data only")
    }
}
