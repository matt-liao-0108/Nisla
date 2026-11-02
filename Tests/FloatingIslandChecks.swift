import SwiftUI
import AppKit

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 0
    @Published var headerHeight: CGFloat = 36
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = false
}

@main struct FloatingIslandChecks {
    @MainActor static func main() throws {
        var processPreferences = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        processPreferences["musicEnabled"] = false
        UserDefaults.standard.setVolatileDomain(processPreferences, forName: UserDefaults.argumentDomain)
        var options = IslandOptions()
        precondition(options.preferredPresentation == "automatic")
        precondition(!options.usesFloatingIsland(nativeSupport: .unsupportedSystem), "Existing preferences must keep the notch on unsupported systems")
        options.presentationStyle = "floating"
        precondition(options.usesFloatingIsland, "Manual floating remains available")
        options.presentationStyle = "notch"
        precondition(!options.usesFloatingIsland, "The original notch presentation must remain selectable")

        for width: CGFloat in [200, 300] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: 36)
            let path = NotchOutline(reveal: 0, shoulders: false, floating: true).path(in: bounds)
            precondition(path.contains(CGPoint(x: width / 2, y: 1)))
            precondition(!path.contains(CGPoint(x: 1, y: 1)), "The compact island needs capsule ends, not notch shoulders")
            precondition(path.contains(CGPoint(x: 1, y: 18)))
            precondition(!path.contains(CGPoint(x: width - 1, y: 1)))
        }
        let full = CGRect(x: 0, y: 0, width: 580, height: 36 + 154 + ShelfGeometry.footerHeight)
        let integrated = ShelfSurfaceShape(collapsedHeight: 36, expandedHeight: full.height,
            shoulders: false, floating: true, integratedFooter: true).path(in: full)
        let detached = ShelfSurfaceShape(collapsedHeight: 36, expandedHeight: full.height,
            shoulders: true, floating: false).path(in: full)
        let footerPoint = CGPoint(x: full.midX, y: full.maxY - 10)
        precondition(integrated.contains(footerPoint), "Floating tabs must sit within the island's continuous surface")
        precondition(!detached.contains(footerPoint), "The original notch keeps its separate footer")
        precondition(!integrated.contains(CGPoint(x: 2, y: 2)))
        print("PASS: compact islands have capsule ends; expanded floating surface contains its footer; original notch remains selectable")

        guard CGMainDisplayID() != 0 else {
            print("SKIP: floating island snapshots require a WindowServer display")
            return
        }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/FloatingIslandPreviews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("NislaFloating-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let preferenceName = "NislaFloating-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer { preferences.removePersistentDomain(forName: preferenceName) }
        let store = PinStore(storageDirectory: fixture, preferences: preferences, interactive: false)
        store.options.appearance = "black"
        store.options.presentationStyle = "floating"
        store.options.shelfWidth = 580
        store.keepOpen = true
        let layout = PanelLayout()
        var note = PinItem(kind: .text, title: "设计备忘", payload: "把常用内容留在手边。\n收纳、日历、Codex 和音乐。")
        note.isNote = true
        store.items = [note, PinItem(kind: .link, title: "Nisla", payload: "https://example.com/nisla")]
        func render(_ name: String, width: CGFloat, height: CGFloat) throws {
            try snapshot(ShelfView().environmentObject(store).environmentObject(layout),
                width: width, height: height, destination: folder.appendingPathComponent(name + ".png"))
        }
        func floatingHeight() -> CGFloat {
            layout.headerHeight + ShelfGeometry.bodyHeight(store.bodyHeight, floating: true, selectedTab: store.selectedTab) + ShelfGeometry.footerHeight
        }
        store.isExpanded = false
        try render("compact-idle", width: 200, height: 36)
        let session = CodexSession(id: "floating-fixture", title: "完善灵动岛交互", project: "Nisla", modifiedAt: .now, isRunning: true)
        store.pinnedSessions = [session]
        store.activities = [session.id: SessionActivity(phase: .running, message: "正在检查界面")]
        store.selectedTab = 1
        try render("compact-codex", width: 300, height: 36)
        store.isExpanded = true
        try render("expanded-codex", width: 580, height: floatingHeight())
        store.selectedTab = 0
        try render("expanded-storage", width: 580, height: floatingHeight())
        // A shrinking panel may lay out before the published preference catches
        // up. Keep its surface and embedded tabs within the native width.
        store.options.shelfWidth = 960
        try render("expanded-storage-shrunk", width: 440, height: floatingHeight())
        store.options.appearance = "glass"
        store.options.shelfWidth = 580
        try render("expanded-storage-glass", width: 580, height: floatingHeight())
        store.selectedTab = 3
        store.musicGuidanceLines = 1
        try render("expanded-music", width: 580, height: layout.headerHeight + store.bodyHeight + ShelfGeometry.footerHeight)
        for reading in [SystemHUDReading(kind: .volume, value: 0.56), SystemHUDReading(kind: .brightness, value: 0.72)] {
            SystemHUD.shared.present(reading)
            let size = SystemHUDGeometry.size(notchWidth: 0, headerHeight: 0)
            precondition(size.height == 44, "A floating HUD must not reserve a hardware-notch header")
            let path = NotchOutline(reveal: 1, shoulders: false, floating: true).path(in: CGRect(origin: .zero, size: size))
            precondition(!path.contains(CGPoint(x: 1, y: 1)))
            precondition(path.contains(CGPoint(x: 1, y: size.height / 2)))
            try render(reading.kind == .volume ? "floating-volume" : "floating-brightness", width: size.width, height: size.height)
        }
        SystemHUD.shared.stop()
        store.selectedTab = 0
        store.options.appearance = "black"
        store.options.presentationStyle = "notch"
        layout.attachedToMenuBar = true
        layout.headerHeight = 32
        layout.notchWidth = 180
        try render("original-notch-storage", width: 580, height: layout.headerHeight + store.bodyHeight + ShelfGeometry.footerHeight)
        print("PASS: rendered compact 200/300 pt, expanded Codex/storage, shrinking width, and original notch fixtures in \(folder.path)")
    }

    @MainActor private static func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, destination: URL) throws {
        let inset: CGFloat = 16
        let canvas = CGSize(width: width + inset * 2, height: height + inset * 2)
        let host = NSHostingView(rootView: view.frame(width: width, height: height).padding(inset)
            .background(LinearGradient(colors: [Color(red: 0.24, green: 0.44, blue: 0.54),
                Color(red: 0.56, green: 0.40, blue: 0.53)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark).environment(\.locale, AppLocalization.shared.locale))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.main.run(until: .now.addingTimeInterval(0.03)) }
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        precondition(bitmap.pixelsWide >= Int(canvas.width) && bitmap.pixelsHigh >= Int(canvas.height))
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
}
