import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Documentation fixtures only. No app delegate, real store, hardware or services.
@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

struct ReadmeDesktop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.22, green: 0.37, blue: 0.47),
                Color(red: 0.10, green: 0.17, blue: 0.25), Color(red: 0.17, green: 0.23, blue: 0.29)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 15) {
                Image(systemName: "apple.logo")
                Text("Nisla").fontWeight(.semibold)
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("09:41").monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 20).frame(height: 32)
            VStack { Spacer(); Text("Nisla · 演示数据 / Demo")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42)).padding(.bottom, 16) }
        }
    }
}

/// Native dashboards in the same attached silhouette and navigation as the app.
struct ReadmeDashboard: View {
    let content: AnyView
    let height: CGFloat
    @EnvironmentObject var store: PinStore
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "rectangle.on.rectangle")
                    Image(systemName: "chevron.up")
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 24).frame(height: 32)
                content.padding(.horizontal, ShelfGeometry.expandedContentInset)
                    .padding(.vertical, 8).frame(height: height)
            }
            .modifier(ShelfMaterial(appearance: "black", reveal: 1, shape: NotchOutline(reveal: 1)))
            .clipShape(NotchOutline(reveal: 1))
            ShelfTabBar().frame(height: ShelfGeometry.footerHeight, alignment: .bottom)
        }
    }
}

@main struct ReadmePreviews {
    @MainActor static func main() throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[L10n.preferenceKey] = AppLanguage.simplifiedChinese.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("docs/assets")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("NislaReadme-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let preferences = UserDefaults(suiteName: "NislaReadme-" + UUID().uuidString)!
        let store = PinStore(storageDirectory: fixture, preferences: preferences, interactive: false)
        store.options.appearance = "black"
        store.options.presentationStyle = "notch"
        store.options.shelfWidth = 580
        store.options.arrivalSound = false
        store.keepOpen = true
        store.isExpanded = true
        let layout = PanelLayout()
        var note = PinItem(kind: .text, title: "设计备忘", payload: "把常用内容放在手边。\n\n- 整理本周灵感\n- 完成界面细节\n- 留一点时间给音乐")
        note.isNote = true; note.tags = ["灵感"]
        let cover = artwork()
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let imageURL = fixture.appendingPathComponent("artwork.png")
        try cover.write(to: imageURL)
        store.items = [note, PinItem(kind: .image, title: "色彩灵感.png", payload: imageURL.path),
            PinItem(kind: .link, title: "项目资料", payload: "https://example.com/design")]
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        store.pinnedSessions = [
            CodexSession(id: "demo-1", title: "完善新的界面布局", project: "Nisla", modifiedAt: date, isRunning: true),
            CodexSession(id: "demo-2", title: "检查中英文切换", project: "Nisla", modifiedAt: date, isRunning: false),
            CodexSession(id: "demo-3", title: "整理发布说明", project: "Nisla", modifiedAt: date, isRunning: false)]
        store.activities = ["demo-1": SessionActivity(phase: .running, message: "正在检查界面细节"),
            "demo-2": SessionActivity(phase: .waiting, message: "等待确认语言选项"),
            "demo-3": SessionActivity(phase: .completed, message: "已完成发布说明")]
        func event(_ id: String, _ title: String, offset: Int, hour: Int, color: NSColor, allDay: Bool = false) -> AgendaEntry {
            let start = Calendar.current.date(byAdding: .hour, value: hour,
                to: Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: date))!)!
            return AgendaEntry(id: id, title: title, calendar: "演示日历", color: color, start: start,
                end: Calendar.current.date(byAdding: allDay ? .day : .hour, value: 1, to: start), allDay: allDay)
        }
        let events = [event("1", "产品设计评审", offset: 0, hour: 14, color: .systemBlue),
            event("2", "整理本周灵感", offset: 0, hour: 16, color: .systemOrange)]
        let agenda = CalendarDashboard(date: .constant(date), events: events,
            reminders: [event("3", "整理本周计划", offset: 0, hour: 18, color: .systemMint)],
            hasEvents: true, hasReminders: true, loading: false, error: nil, authorize: { _ in }, refresh: {})
        let track = MusicTrack(player: .spotify, title: "Late Afternoon", artist: "Nisla Studio",
            album: "Quiet Hours", playing: true, duration: 246, position: 76, artworkURL: nil, artwork: cover)
        let music = MusicDashboard(track: track, enabled: true, busy: false, status: "演示数据",
            remoteArtwork: false, selectedPlayer: .constant("auto"), command: { _ in }, open: { _ in },
            enable: {}, refresh: {}, showProgress: .constant(true), outputVolume: 0.65)
        let modes = ["storage", "codex", "calendar", "music", "volume", "brightness"]
        let heights: [CGFloat] = [32 + 154 + 42, 32 + ShelfGeometry.codexBodyHeight(sessionCount: 3) + 42,
            32 + ShelfGeometry.calendarBodyHeight(weekRows: 5) + 42,
            32 + ShelfGeometry.musicBodyHeight(hasTrack: true, showsProgress: true) + 42, 76, 76]
        func panel(_ mode: Int) -> AnyView {
            switch mode {
            case 0, 1:
                store.selectedTab = mode
                return AnyView(ShelfView().environmentObject(store).environmentObject(layout))
            case 2:
                store.selectedTab = 2
                return AnyView(ReadmeDashboard(content: AnyView(agenda), height: heights[2] - 74).environmentObject(store))
            case 3:
                store.selectedTab = 3
                return AnyView(ReadmeDashboard(content: AnyView(music), height: heights[3] - 74).environmentObject(store))
            default:
                return AnyView(SystemHUDNotificationBanner(reading: SystemHUDReading(
                    kind: mode == 4 ? .volume : .brightness, value: mode == 4 ? 0.65 : 0.8, muted: false),
                    headerHeight: 32, appearance: "black"))
            }
        }
        func scene(_ content: AnyView, width: CGFloat, height: CGFloat) -> AnyView {
            AnyView(ZStack(alignment: .top) {
                ReadmeDesktop()
                content.frame(width: width, height: height, alignment: .top).clipped()
            }.frame(width: 800, height: 380)
                .environment(\.colorScheme, .dark).environment(\.locale, AppLocalization.shared.locale))
        }
        for index in modes.indices {
            store.isExpanded = true
            let image = try render(scene(panel(index), width: index < 4 ? 580 : 470, height: heights[index]))
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(modes[index] + ".png"))
        }

        // Deterministic illustration using the same production easing curves.
        // It is not a screen recording and does not issue volume/brightness commands.
        let framesPerMode = 40, fps = 15.0
        let gif = CGImageDestinationCreateWithURL(output.appendingPathComponent("notch-overview.gif") as CFURL,
            UTType.gif.identifier as CFString, framesPerMode * modes.count, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for mode in modes.indices {
            for frame in 0..<framesPerMode {
                let t = Double(frame) / fps
                let openAt = 0.25, closeAt = 2.05
                let expandedWidth: CGFloat = mode < 4 ? 580 : 470
                let width: CGFloat, height: CGFloat, reveal: Double
                if t < openAt {
                    width = 390; height = 32; reveal = 0
                } else if t < closeAt {
                    let p = IslandMotion.progress((t - openAt) / IslandMotion.shelfDuration(opening: true), opening: true)
                    width = 390 + (expandedWidth - 390) * p.width
                    height = 32 + (heights[mode] - 32) * p.height
                    reveal = min(1, max(0, (t - openAt) / 0.22))
                } else {
                    let p = IslandMotion.progress((t - closeAt) / IslandMotion.shelfDuration(opening: false), opening: false)
                    width = expandedWidth + (390 - expandedWidth) * p.width
                    height = heights[mode] + (32 - heights[mode]) * p.height
                    reveal = max(0, 1 - (t - closeAt) / 0.12)
                }
                store.isExpanded = true
                let expanded = panel(mode)
                let animated = AnyView(ZStack(alignment: .top) {
                    NotchOutline(reveal: CGFloat(reveal)).fill(.black)
                        .frame(height: height - (mode < 4 ? ShelfGeometry.footerHeight * reveal : 0))
                        .frame(maxHeight: .infinity, alignment: .top)
                    expanded.frame(width: expandedWidth, height: heights[mode], alignment: .top)
                        .opacity(reveal).clipped()
                }.frame(width: width, height: height, alignment: .top)
                    .clipShape(NotchOutline(reveal: CGFloat(reveal))))
                let image = try render(scene(animated, width: width, height: height))
                CGImageDestinationAddImage(gif, image.cgImage!,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            }
        }
        precondition(CGImageDestinationFinalize(gif))
        let source = CGImageSourceCreateWithURL(output.appendingPathComponent("notch-overview.gif") as CFURL, nil)!
        precondition(CGImageSourceGetCount(source) == framesPerMode * modes.count)
        print("PASS: six full-notch PNGs and 240-frame GIF; synthetic data only, no real services or hardware commands")
    }

    @MainActor static func render(_ view: AnyView) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 380),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    static func artwork() -> Data {
        let image = NSImage(size: NSSize(width: 160, height: 160))
        image.lockFocus()
        NSGradient(colors: [.systemIndigo, .systemPink, .systemOrange])!
            .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 160, height: 160)), angle: -60)
        for i in 0..<6 {
            NSColor.white.withAlphaComponent(0.13).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: -30 + i * 13, y: -24 + i * 10, width: 160, height: 160))
            ring.lineWidth = 2; ring.stroke()
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
