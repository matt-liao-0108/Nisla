import AppKit
import SwiftUI
import Combine

/// Runs the PRODUCTION IslandPanel with synthetic data. No AppDelegate,
/// live menu scanning, music polling, event taps or permission requests.
@main struct MenuBarWindowPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        let quit = NSMenuItem(title: "退出避让测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app; submenu.addItem(quit); item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandAvoidance-" + UUID().uuidString)
        let store = PinStore(storageDirectory: directory,
            preferences: UserDefaults(suiteName: "IslandAvoidance-" + UUID().uuidString)!, interactive: false)
        store.options.appearance = "glass"; store.selectedTab = 1
        store.isExpanded = true; store.keepOpen = true
        store.pinnedSessions = [CodexSession(id: "fixture", title: "菜单栏避让 · 演示任务", project: "Fixture", modifiedAt: .now, isRunning: true)]
        store.activities = ["fixture": SessionActivity(phase: .running)]
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let panel = IslandPanel(store: store, screen: screen)
        panel.title = "Island 菜单栏避让测试"
        panel.orderFrontRegardless(); app.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        let output = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("MenuBarWindowReport.json")
        func report() {
            let attached = abs(panel.frame.maxY - screen.frame.maxY) < 0.5
            let data: [String: Any] = ["expanded": store.isExpanded, "attachedToTop": attached,
                "panelTop": panel.frame.maxY, "screenTop": screen.frame.maxY,
                "width": panel.frame.width, "height": panel.frame.height]
            try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        }
        let change = store.objectWillChange.sink { _ in
            Task { @MainActor in
                panel.setExpanded(store.isExpanded)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { report() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { report() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { app.terminate(nil) }
        print("READY: production IslandPanel, unknown geometry fallback; fixture data only")
        app.run()
        withExtendedLifetime((store, panel, change)) {}
    }
}
