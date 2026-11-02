import SwiftUI
import AppKit

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

@main struct SettingsNavigationChecks {
    @MainActor static func main() throws {
        let language: AppLanguage = ProcessInfo.processInfo.environment["NISLA_SETTINGS_LANGUAGE"] == "zh-Hans" ? .simplifiedChinese : .english
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[L10n.preferenceKey] = language.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NislaSettingsCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinStore(storageDirectory: directory,
            preferences: UserDefaults(suiteName: "NislaSettingsCheck-" + UUID().uuidString)!, interactive: false)
        let host = NSHostingView(rootView: SettingsView(selectedTab: .content).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        func controls(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        let segments = controls(in: host)
        precondition(segments.count == 1, "Settings must expose one fixed native top tab control")
        let tabs = segments[0]
        precondition(tabs.segmentCount == SettingsTab.allCases.count)
        precondition(SettingsTab.allCases == [.appearance, .content, .agent, .calendar, .music, .shortcuts])
        precondition(window.standardWindowButton(.closeButton)?.isHidden == false)
        precondition(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        precondition(window.standardWindowButton(.zoomButton)?.isHidden == true)
        precondition(window.toolbar == nil, "Settings navigation must not be moved into toolbar overflow")
        let labels = SettingsTab.allCases.map(\.title)
        for index in labels.indices {
            precondition(tabs.label(forSegment: index) == labels[index], "All six translated tabs must remain visible")
        }
        precondition(tabs.selectedSegment == SettingsTab.content.rawValue)
        precondition(tabs.frame.width >= tabs.fittingSize.width - 1, "Translated tabs must fit without compression")
        let frame = tabs.convert(tabs.bounds, to: host)
        let topInset = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        precondition(!tabs.isHiddenOrHasHiddenAncestor && topInset >= 0 && topInset < 44,
            "All settings navigation must remain visible at the top of the content area")
        let shortcutIndex = SettingsTab.allCases.firstIndex(of: .shortcuts)!
        precondition(shortcutIndex == 5)
        tabs.selectedSegment = shortcutIndex
        precondition(tabs.sendAction(tabs.action, to: tabs.target), "The top tabs must dispatch selection changes")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        precondition(tabs.selectedSegment == shortcutIndex)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/SettingsPreviews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("tabs-\(language.rawValue).png"))
        print("PASS: \(language.rawValue) settings shows six fixed top tabs with complete labels, no toolbar overflow, and working native selection; isolated data only")
    }
}
