import SwiftUI
import AppKit

@main struct LiveActivityChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let marker = NSImage(size: NSSize(width: 23, height: 23))
        var attempted: [String] = []
        let icon = CodexIconResolver.image(in: [URL(fileURLWithPath: "/fixture/Codex.app"), URL(fileURLWithPath: "/fixture/ChatGPT.app")]) { url in
            attempted.append(url.path)
            return url.path == "/fixture/ChatGPT.app/Contents/Resources/icon-chatgpt.png" ? marker : nil
        }
        precondition(icon === marker)
        precondition(!attempted.contains(where: { $0.contains("icon-codex") }), "The blue terminal asset must never replace the requested knot icon")
        precondition(CodexIconResolver.image(in: [], load: { _ in marker }) == nil)
        print("PASS: requested knot icon is resolved across installed app candidates, never the blue terminal asset")
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/LiveActivityPreviews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let song = MusicTrack(player: .netease, title: "Indeed", artist: "演示歌手", album: "演示数据", playing: true, duration: 180, position: 12, artworkURL: nil)
        let agent = CompactActivity.resolve(selectedTab: 1, codexVisible: true, running: 2, waiting: 0, completed: false, codexTitle: "Codex", musicVisible: true, track: song)
        precondition(agent.kind == .codex && agent.running && agent.count == 2 && agent.tab == 1)
        let music = CompactActivity.resolve(selectedTab: 3, codexVisible: true, running: 2, waiting: 0, completed: false, codexTitle: "Codex", musicVisible: true, track: song)
        precondition(music.kind == .music && music.title == "Indeed" && music.tab == 3)
        let hidden = CompactActivity.resolve(selectedTab: 3, codexVisible: false, running: 2, waiting: 1, completed: true, codexTitle: "Codex", musicVisible: false, track: song)
        precondition(hidden.kind == .idle && hidden.tab == nil)
        let waiting = CompactActivity.resolve(selectedTab: 1, codexVisible: true, running: 0, waiting: 1, completed: false, codexTitle: "Codex", musicVisible: false, track: nil)
        precondition(waiting.waiting && !waiting.running)
        for index in 0..<5 {
            precondition(ActivityBarMotion.height(index: index, time: 10, playing: true, reduceMotion: true) == 4)
            precondition(ActivityBarMotion.height(index: index, time: 10, playing: false, reduceMotion: false) == 4)
            precondition((4...15).contains(ActivityBarMotion.height(index: index, time: 10, playing: true, reduceMotion: false)))
        }
        for (name, activity) in [("codex", agent), ("music", music), ("waiting", waiting)] {
            for (width, notch) in [(390, 180), (270, 0)] {
                let host = NSHostingView(rootView: HeaderFixture(activity: activity, width: CGFloat(width), notch: CGFloat(notch)))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false; window.backgroundColor = .clear; window.contentView = host
                host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name)-\(width).png"))
                if notch > 0 {
                    let scale = CGFloat(bitmap.pixelsWide) / CGFloat(width)
                    for x in stride(from: (width - notch) / 2 + 4, to: (width + notch) / 2 - 4, by: 5) {
                        let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(16 * scale))!.usingColorSpace(.sRGB)!
                        precondition(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01, "Activity crossed into physical notch")
                    }
                }
            }
        }
        print("PASS: live-activity priority, hidden tabs, Codex left/right arrangement and physical notch clearance (fixtures only)")
    }
}

private struct HeaderFixture: View {
    let activity: CompactActivity
    let width: CGFloat
    let notch: CGFloat
    var body: some View {
        let gap = notch > 0 ? notch + 12 : 0
        let side = (width - 36 - gap) / 2
        HStack(spacing: 0) {
            CompactActivityLabel(activity: activity, remoteArtwork: false).frame(width: side)
            Color.clear.frame(width: gap)
            CompactActivityIndicator(activity: activity, tint: .mint).frame(width: side, alignment: .trailing)
        }.padding(.horizontal, 18).frame(width: width, height: 32).background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
    }
}
