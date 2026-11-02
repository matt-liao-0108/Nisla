import SwiftUI

struct MusicSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var music = MusicStore.shared
    var body: some View {
        Form {
            Section(L10n.text("音乐读取与控制")) {
                Toggle(L10n.text("启用音乐功能"), isOn: $music.enabled)
                Text(L10n.text("如果系统灵动岛已满足音乐控制需求，可关闭此功能并隐藏音乐页，继续使用系统控制。"))
                    .font(.caption).foregroundStyle(.secondary)
                MusicSourcePicker()
                Text(L10n.text("Apple Music 与 Spotify 使用应用脚本接口，首次访问时需要自动化授权。只读取播放信息；仅在点击控制按钮时改变播放，不会自动打开播放器或开始播放。")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("网易云音乐与 QQ 音乐通过内置系统“正在播放”组件连接，无需额外安装工具。请先在播放器中播放歌曲，并确认控制中心正在播放中能看到它。只能控制当前系统播放来源，不能强行切换后台播放器；此通道使用非公开接口，未来系统更新可能失效。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("加载播放器提供的网络封面"), isOn: $music.remoteArtwork)
                Text(L10n.text("默认开启，会向播放器提供的封面地址发起 HTTPS 请求；可手动关闭。歌曲信息不保存、不上传至 AI 服务。")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("刷新播放器信息")) { Task { await music.refresh() } }.disabled(!music.enabled || music.busy)
                Text(L10n.text(music.status)).font(.caption).textSelection(.enabled)
            }
        }.formStyle(.grouped)
    }
}

private struct MusicSourcePicker: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var music = MusicStore.shared
    var body: some View {
        Picker(L10n.text("播放器"), selection: $music.selectedPlayer) {
            Text(L10n.text("自动识别")).tag("auto")
            ForEach(MusicPlayer.allCases) { player in Text(L10n.text(player.title)).tag(player.rawValue) }
        }
    }
}

struct MusicShelf: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    @ObservedObject private var music = MusicStore.shared
    @State private var availableWidth: CGFloat = 0
    var body: some View {
        MusicDashboard(track: music.track, enabled: music.enabled, busy: music.busy,
                       status: music.status, remoteArtwork: music.remoteArtwork, selectedPlayer: $music.selectedPlayer,
                       command: { command in Task { await music.control(command) } },
                       open: { music.open($0) }, enable: { music.enabled = true }, refresh: { Task { await music.refresh() } },
                       showProgress: $store.musicShowsProgress,
                       outputVolume: music.outputVolume)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                availableWidth = width
                updateGuidanceHeight()
            }
            .onAppear(perform: updateGuidanceHeight)
            .onChange(of: music.status) { _, _ in updateGuidanceHeight() }
            .onChange(of: store.options.shelfWidth) { _, _ in updateGuidanceHeight() }
            .onChange(of: localization.selection) { _, _ in updateGuidanceHeight() }
    }

    private func updateGuidanceHeight() {
        let panelContentWidth = availableWidth > 0 ? availableWidth
            : store.options.shelfWidth - 2 * ShelfGeometry.expandedContentInset
        let width = max(1, panelContentWidth - 16)
        let lines = MusicGuidanceLayout.lineCount(L10n.text(music.status), width: width)
        if store.musicGuidanceLines != lines { store.musicGuidanceLines = lines }
    }

}

enum MusicGuidanceLayout {
    /// Count actual line fragments instead of dividing rounded text bounds by
    /// fractional font metrics (13 / 12.955 incorrectly rounded up to 2 lines).
    static func lineCount(_ text: String, width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 3 }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 3
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in count += 1 }
        return min(3, max(1, count))
    }
}
