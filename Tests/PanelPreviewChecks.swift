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

@MainActor final class PreviewSelection: ObservableObject {
    @Published var date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!
    @Published var player = "auto"
}

@main struct PanelPreviewChecks {
    @MainActor static func main() throws {
        // Process-only override: never change the user's saved language.
        let previewLanguage = ProcessInfo.processInfo.environment["NISLA_PREVIEW_LANGUAGE"].flatMap(AppLanguage.init(rawValue:))
        if let previewLanguage {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[L10n.preferenceKey] = previewLanguage.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        _ = NSApplication.shared
        precondition(ShelfTab.pins.title == "收纳")
        precondition(NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil) != nil)
        let folder = previewLanguage.map { ".build/PanelPreviews-\($0.rawValue)" } ?? ".build/PanelPreviews"
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for highlighted in [false, true] {
            let targets = HStack(spacing: 10) {
                StorageDropTarget(highlighted: !highlighted).frame(maxWidth: .infinity)
                AirDropTarget(highlighted: highlighted).frame(width: 132)
            }.frame(width: 392, height: 104)
            try snapshot(targets, width: 392, height: 104, padded: false,
                destination: output.appendingPathComponent("airdrop-\(highlighted).png"))
        }
        let selection = PreviewSelection()
        let recent = [PinItem(kind: .file, title: "演示文稿.pdf", payload: "/tmp/fixture.pdf"),
                      PinItem(kind: .text, title: "设计备忘", payload: "这是一段很长的设计备忘文字，用于检查收纳缩略卡片是否在边界处正确省略多余内容。"),
                      PinItem(kind: .link, title: "设计资料链接示例", payload: "https://example.com/design")]
        try snapshot(StorageDropTarget(highlighted: true, totalCount: 12, recentItems: recent),
            width: 250, height: 104, padded: false,
            destination: output.appendingPathComponent("storage-drop-with-items.png"))
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: selection.date)
        func event(_ id: String, title: String, offset: Int, hour: Int, color: NSColor, allDay: Bool = false) -> AgendaEntry {
            let start = calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: day)!)!
            let end = calendar.date(byAdding: allDay ? .day : .hour, value: 1, to: start)!
            return AgendaEntry(id: id, title: title, calendar: "预览数据", color: color, start: start, end: end, allDay: allDay)
        }
        let events = [event("1", title: "产品设计评审", offset: 0, hour: 14, color: .systemBlue),
                      event("2", title: "周末的留白", offset: 1, hour: 0, color: .systemOrange, allDay: true),
                      event("3", title: "下周计划", offset: 3, hour: 10, color: .systemPurple)]
        let todo = event("4", title: "整理设计灵感", offset: 0, hour: 18, color: .systemMint)
        let agenda = CalendarDashboard(date: Binding(get: { selection.date }, set: { selection.date = $0 }), events: events, reminders: [todo], hasEvents: true, hasReminders: true, loading: false, error: nil, authorize: { _ in }, refresh: {})
        var track = NativeMusic.parseFields(["Late Afternoon", "Island Studio", "Quiet Hours · 演示数据", "playing", "246000", "76", ""], player: .spotify)!
        track.artwork = cover()
        func music(showsProgress: Bool) -> MusicDashboard {
            MusicDashboard(track: track, enabled: true, busy: false, status: "预览", remoteArtwork: false, selectedPlayer: Binding(get: { selection.player }, set: { selection.player = $0 }), command: { _ in }, open: { _ in }, enable: {}, refresh: {}, showProgress: .constant(showsProgress), outputVolume: 0.72)
        }
        let emptyMusic = MusicDashboard(track: nil, enabled: true, busy: false,
            status: "请先在 网易云音乐 播放歌曲，并确认 macOS 控制中心的“正在播放”显示此播放器。",
            remoteArtwork: false, selectedPlayer: .constant("auto"), command: { _ in }, open: { _ in }, enable: {}, refresh: {}, showProgress: .constant(false))
        let shortGuidance = MusicDashboard(track: nil, enabled: true, busy: false,
            status: "请在 Apple Music、Spotify、网易云音乐或 QQ 音乐中播放歌曲。",
            remoteArtwork: false, selectedPlayer: .constant("auto"), command: { _ in }, open: { _ in }, enable: {}, refresh: {}, showProgress: .constant(false))
        for width in [440, 580] {
            let calendarHeight = Int(ShelfGeometry.calendarBodyHeight(weekRows: AgendaRules.monthCells(for: selection.date).count / 7))
            try snapshot(agenda, width: width, height: calendarHeight, destination: output.appendingPathComponent("calendar-\(width).png"))
            for progress in [false, true] {
                let height = Int(ShelfGeometry.musicBodyHeight(hasTrack: true, showsProgress: progress))
                try snapshot(music(showsProgress: progress), width: width, height: height,
                    destination: output.appendingPathComponent("music\(progress ? "-progress" : "")-\(width).png"))
            }
            try snapshot(emptyMusic, width: width, height: Int(ShelfGeometry.musicBodyHeight(hasTrack: false, showsProgress: false)),
                destination: output.appendingPathComponent("music-empty-\(width).png"))
            try snapshot(shortGuidance, width: width, height: Int(ShelfGeometry.musicBodyHeight(hasTrack: false, showsProgress: false, guidanceLines: 1)),
                destination: output.appendingPathComponent("music-empty-short-\(width).png"))
        }
        selection.date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        for width in [440, 580] {
            try snapshot(agenda, width: width, height: Int(ShelfGeometry.calendarBodyHeight(weekRows: 6)), destination: output.appendingPathComponent("calendar-six-rows-\(width).png"))
        }
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandCodexLayout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let store = PinStore(storageDirectory: fixtureDirectory,
            preferences: UserDefaults(suiteName: "IslandCodexLayout-" + UUID().uuidString)!, interactive: false)
        store.options.appearance = "black"; store.isExpanded = true; store.selectedTab = 1
        let layout = PanelLayout()
        for width in [440, 580] {
            store.options.shelfWidth = CGFloat(width)
            for count in [0, 1, 2, 4, 6] {
                store.pinnedSessions = (0..<count).map { CodexSession(id: "preview-\($0)",
                    title: "\($0 == 0 ? "Guardian review" : "设计检查 \($0 + 1)")", project: "Fixture", modifiedAt: .now, isRunning: false) }
                store.activities = Dictionary(uniqueKeysWithValues: store.pinnedSessions.map { ($0.id, SessionActivity(phase: .completed)) })
                let height = Int(layout.headerHeight + store.bodyHeight + ShelfGeometry.footerHeight)
                let view = ShelfView().environmentObject(store).environmentObject(layout)
                    .frame(width: CGFloat(width), height: CGFloat(height)).background(Color(white: 0.08))
                try snapshot(view, width: width, height: height, padded: false,
                    destination: output.appendingPathComponent("codex-\(count)-\(width).png"))
            }
        }
        // Reproduce @Published willSet: a smaller native window can lay out
        // while the preference still contains the previous larger width.
        let resizeHeight = Int(layout.headerHeight + store.bodyHeight + ShelfGeometry.footerHeight)
        for storedWidth in [440, 960] {
            store.options.shelfWidth = CGFloat(storedWidth)
            let view = ShelfView().environmentObject(store).environmentObject(layout)
                .frame(width: 440, height: CGFloat(resizeHeight)).background(Color(white: 0.08))
            try snapshot(view, width: 440, height: resizeHeight, padded: false,
                destination: output.appendingPathComponent("resize-stored-\(storedWidth).png"))
        }
        let currentWidthRender = try Data(contentsOf: output.appendingPathComponent("resize-stored-440.png"))
        let staleWidthRender = try Data(contentsOf: output.appendingPathComponent("resize-stored-960.png"))
        precondition(currentWidthRender == staleWidthRender,
            "Stale stored widths must not shift the content in a shrinking native window")
        try snapshot(Image(nsImage: IslandBrand.menuIcon()).resizable().interpolation(.none)
            .frame(width: 80, height: 80).padding(10), width: 100, height: 100, padded: false,
            destination: output.appendingPathComponent("menu-brand.png"))
        let compactTrack = MusicTrack(player: .spotify, title: "男人信什麼", artist: "演示艺人", album: "Fixture", playing: true,
            duration: 246, position: 76, artworkURL: nil, artwork: track.artwork)
        let activity = CompactActivity.resolve(selectedTab: 3, codexVisible: false, running: 0, waiting: 0, completed: false,
            codexTitle: "", musicVisible: true, track: compactTrack)
        let wing = (390 - 2 * ShelfGeometry.headerContentInset - 192) / 2
        let compact = HStack(spacing: 0) {
            CompactActivityLabel(activity: activity, remoteArtwork: false).frame(width: wing)
            Color.clear.frame(width: 192)
            CompactActivityIndicator(activity: activity, tint: .mint).frame(minWidth: 40)
                .frame(width: wing, alignment: .trailing)
        }.padding(.horizontal, ShelfGeometry.headerContentInset).frame(height: 32).background(.black)
            .clipShape(NotchOutline(reveal: 0)).background(Color(white: 0.08))
        try snapshot(compact, width: 390, height: 32, padded: false,
            destination: output.appendingPathComponent("compact-music.png"))
        store.isExpanded = false; store.selectedTab = 1
        store.pinnedSessions = [CodexSession(id: "avoidance-fixture", title: "设计任务 · 演示数据", project: "Fixture", modifiedAt: .now, isRunning: true)]
        store.activities = ["avoidance-fixture": SessionActivity(phase: .running)]
        for mode in [CompactPresentation.full, .icons, .notch] {
            layout.compactPresentation = mode
            let width = Int(layout.notchWidth + mode.extraWidth)
            let preview = ShelfView().environmentObject(store).environmentObject(layout)
                .frame(width: CGFloat(width), height: 32)
            try snapshot(preview, width: width, height: 32, padded: false,
                destination: output.appendingPathComponent("menu-avoidance-\(mode).png"))
        }
        store.isExpanded = true
        layout.attachedToMenuBar = false; layout.notchWidth = 0
        for width in [440, 580] {
            store.options.shelfWidth = CGFloat(width)
            let height = Int(layout.headerHeight + store.bodyHeight + ShelfGeometry.footerHeight)
            let view = ShelfView().environmentObject(store).environmentObject(layout)
                .frame(width: CGFloat(width), height: CGFloat(height))
            try snapshot(view, width: width, height: height, padded: false,
                destination: output.appendingPathComponent("floating-codex-\(width).png"))
        }
        print("PASS: native calendar/music, compact title and 0/1/2/4/6-row Codex layouts render with fixture data only")
    }

    @MainActor static func snapshot<V: View>(_ view: V, width: Int, height: Int, padded: Bool = true, destination: URL) throws {
        let host = NSHostingView(rootView: view.padding(.horizontal, padded ? ShelfGeometry.expandedContentInset : 0).padding(.vertical, padded ? 8 : 0).frame(width: CGFloat(width), height: CGFloat(height)).background(.black).environment(\.colorScheme, .dark).environment(\.locale, AppLocalization.shared.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black; window.contentView = host
        host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        precondition(bitmap.pixelsWide >= width && bitmap.pixelsHigh >= height)
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }

    static func cover() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGradient(colors: [.systemIndigo, .systemPink.withAlphaComponent(0.75), .systemOrange])!.draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 160, height: 160)), angle: -65)
        for index in 0..<6 {
            NSColor.white.withAlphaComponent(0.10).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: -30 + index * 12, y: -20 + index * 8, width: 160, height: 160))
            path.lineWidth = 2; path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
}
