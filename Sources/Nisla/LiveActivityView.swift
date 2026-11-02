import SwiftUI
import AppKit

enum CompactActivityKind { case idle, codex, music }

struct CompactActivity {
    let kind: CompactActivityKind
    var title = "Nisla"
    var track: MusicTrack?
    var running = false
    var waiting = false
    var completed = false
    var count = 0

    static func resolve(selectedTab: Int, codexVisible: Bool, running: Int, waiting: Int,
                        completed: Bool, codexTitle: String, musicVisible: Bool, track: MusicTrack?) -> Self {
        let hasAgent = codexVisible && (running > 0 || waiting > 0 || completed)
        let song = musicVisible ? track : nil
        // Keep the user's selected live activity when both sources are active.
        if let song, selectedTab == 3 || (!hasAgent && song.playing) {
            return Self(kind: .music, title: song.title, track: song, running: song.playing)
        }
        if hasAgent {
            return Self(kind: .codex, title: codexTitle, running: running > 0, waiting: waiting > 0,
                        completed: completed, count: max(running, waiting))
        }
        if let song { return Self(kind: .music, title: song.title, track: song, running: song.playing) }
        return Self(kind: .idle)
    }

    var tab: Int? { switch kind { case .idle: nil; case .codex: 1; case .music: 3 } }
}

struct CompactActivityLabel: View {
    @ObservedObject private var localization = AppLocalization.shared
    let activity: CompactActivity
    let remoteArtwork: Bool
    var showTitle = true
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if activity.kind == .codex { CodexApplicationIcon() }
                else if let track = activity.track { MusicArtwork(track: track, remoteArtwork: remoteArtwork) }
                else { Image(systemName: "tray").font(.system(size: 14)).foregroundStyle(.white) }
            }.frame(width: 23, height: 23).clipShape(RoundedRectangle(cornerRadius: 5))
            if showTitle { Text(activity.title).font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.tail).foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactActivityIndicator: View {
    @ObservedObject private var localization = AppLocalization.shared
    let activity: CompactActivity
    let tint: Color
    var showCount = true
    var body: some View {
        HStack(spacing: 5) {
            if activity.waiting {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            } else if activity.running || activity.kind == .music {
                LiveActivityBars(playing: activity.running, tint: activity.kind == .music ? .white.opacity(0.65) : tint)
            } else if activity.completed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
            }
            if activity.kind == .codex && activity.count > 1 && showCount {
                Text("\(activity.count)").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            }
        }.frame(minWidth: 24, minHeight: 23)
        .accessibilityLabel(activity.waiting ? L10n.text("Codex 等待回答") : activity.kind == .codex ? L10n.text("Codex 活动状态") : activity.running ? L10n.text("音乐正在播放") : L10n.text("音乐已暂停"))
    }
}

struct LiveActivityBars: View {
    @ObservedObject private var localization = AppLocalization.shared
    let playing: Bool
    var tint: Color = .white.opacity(0.65)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing || reduceMotion)) { context in
            HStack(spacing: 2) {
                ForEach(0..<5) { index in
                    Capsule().fill(tint).frame(width: 2.5, height: ActivityBarMotion.height(index: index,
                        time: context.date.timeIntervalSinceReferenceDate, playing: playing, reduceMotion: reduceMotion))
                }
            }.frame(width: 23, height: 18)
        }.accessibilityHidden(true)
    }
}

enum ActivityBarMotion {
    static func height(index: Int, time: Double, playing: Bool, reduceMotion: Bool) -> CGFloat {
        guard playing, !reduceMotion else { return 4 }
        return 4 + 11 * (0.5 + 0.5 * sin(time * 3.6 - Double(index) * 0.85))
    }
}

struct CodexApplicationIcon: View {
    @ObservedObject private var localization = AppLocalization.shared
    // Resolve locally: do not ship another application's artwork with Island.
    @MainActor private static let installedIcon: NSImage? = {
        let applicationFolders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let candidates = applicationFolders.flatMap { folder in ["Codex.app", "ChatGPT.app"].map { folder.appendingPathComponent($0) } }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == "com.openai.codex" }) else { return nil }
        if let image = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/icon-codex-light.png")) { return image }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()
    var body: some View {
        if let icon = Self.installedIcon {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.36, green: 0.38, blue: 0.88))
                Image(systemName: "terminal.fill").font(.system(size: 13)).foregroundStyle(.white)
            }.accessibilityLabel("Codex")
        }
    }
}

struct MusicArtwork: View {
    @ObservedObject private var localization = AppLocalization.shared
    let track: MusicTrack?
    let remoteArtwork: Bool
    var body: some View {
        if let data = track?.artwork, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if remoteArtwork, let url = track?.artworkURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else { placeholder }
    }
    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.09)
            Image(systemName: "music.note").resizable().scaledToFit().padding(7).foregroundStyle(.white.opacity(0.55))
        }
    }
}
