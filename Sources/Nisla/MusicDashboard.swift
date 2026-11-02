import SwiftUI

struct MusicDashboard: View {
    @ObservedObject private var localization = AppLocalization.shared
    let track: MusicTrack?
    let enabled: Bool
    let busy: Bool
    let status: String
    let remoteArtwork: Bool
    @Binding var selectedPlayer: String
    let command: (MusicCommand) -> Void
    let open: (MusicPlayer) -> Void
    let enable: () -> Void
    let refresh: () -> Void
    @Binding var showProgress: Bool
    var outputVolume: Double? = nil

    var body: some View {
        VStack(spacing: track == nil ? 14 : 20) {
            HStack(spacing: 14) {
                Button {
                    if let track { open(track.player) }
                } label: {
                    MusicArtwork(track: track, remoteArtwork: remoteArtwork)
                        .frame(width: 62, height: 62).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) {
                            if let player = track?.player {
                                Image(systemName: player == .spotify ? "waveform" : "music.note")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 23, height: 23).background(player.badgeColor, in: RoundedRectangle(cornerRadius: 7))
                                    .offset(x: 4, y: 4)
                            }
                        }
                }.buttonStyle(.plain).disabled(track == nil).help(L10n.text("在播放器中打开"))
                VStack(alignment: .leading, spacing: 5) {
                    Text(track?.title ?? L10n.text("让音乐留在身边")).font(.system(size: 17, weight: .medium)).lineLimit(1)
                        .help(track?.title ?? L10n.text("让音乐留在身边"))
                    Text(track?.artist.isEmpty == false ? track!.artist : track.map { L10n.text($0.player.title) } ?? L10n.text("Apple Music · Spotify · 网易云 · QQ"))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.50)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let track {
                    LiveActivityBars(playing: track.playing, tint: .white.opacity(0.90))
                        .frame(width: 26).padding(.leading, 6)
                }
            }

            if let track {
                HStack(spacing: 0) {
                    sourceMenu.frame(maxWidth: .infinity)
                    control("shuffle", .shuffle, L10n.text("切换随机播放"), prominent: false).frame(maxWidth: .infinity)
                    control("backward.fill", .previous, L10n.text("上一首"), prominent: false).frame(maxWidth: .infinity)
                    control(track.playing ? "pause.fill" : "play.fill", .toggle, track.playing ? L10n.text("暂停") : L10n.text("播放"), prominent: true).frame(maxWidth: .infinity)
                    control("forward.fill", .next, L10n.text("下一首"), prominent: false).frame(maxWidth: .infinity)
                    Button { open(track.player) } label: {
                        Image(systemName: "macwindow").font(.system(size: 16)).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 30, height: 42).contentShape(Rectangle())
                    }.buttonStyle(MusicControlStyle()).frame(maxWidth: .infinity)
                        .help(L10n.text("在 \(track.player.title) 中打开")).accessibilityLabel(L10n.text("在播放器中打开"))
                }.frame(maxWidth: .infinity)
                if showProgress {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 6) {
                        GeometryReader { geometry in
                            let fraction = track.duration > 0 ? min(1, track.elapsed(at: context.date) / track.duration) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.13))
                                Capsule().fill(.white.opacity(0.88)).frame(width: geometry.size.width * fraction)
                            }
                        }.frame(height: 3).accessibilityHidden(true)
                        HStack {
                            Text(clock(track.elapsed(at: context.date)))
                            Spacer()
                            Text(clock(track.duration))
                        }
                    }.font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.38))
                        .accessibilityElement(children: .combine)
                }
                }
            } else {
                Text(L10n.text(status)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                HStack(spacing: 10) {
                    if !enabled {
                        Button(L10n.text("连接播放器")) { enable() }.buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.white.opacity(0.12), in: Capsule())
                    } else {
                        sourceMenu
                        Button { refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).disabled(busy).help(L10n.text("刷新播放信息"))
                    }
                    Spacer()
                    Menu(L10n.text("打开播放器")) {
                        ForEach(MusicPlayer.allCases) { player in Button(player.title) { open(player) } }
                    }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }.padding(.horizontal, 8).padding(.top, 10).foregroundStyle(.white)
    }

    private var sourceMenu: some View {
        Menu {
            Picker(L10n.text("跟随播放器"), selection: $selectedPlayer) {
                Text(L10n.text("自动识别")).tag("auto")
                ForEach(MusicPlayer.allCases) { player in Text(L10n.text(player.title)).tag(player.rawValue) }
            }
            Divider()
            Toggle(L10n.text("显示播放进度"), isOn: $showProgress)
            if let outputVolume {
                Text(L10n.text("系统输出音量：\(Int(outputVolume * 100))%（只读）"))
            }
        } label: {
            Image(systemName: "list.bullet").font(.system(size: 15)).foregroundStyle(.white.opacity(0.35))
                .frame(width: 30, height: track == nil ? 28 : 42)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("选择跟随的播放器"))
            .accessibilityLabel(L10n.text("播放器来源"))
    }

    private func control(_ symbol: String, _ value: MusicCommand, _ title: String, prominent: Bool) -> some View {
        let shuffleActive = value == .shuffle && track?.shuffleEnabled == true
        return Button { command(value) } label: {
            Image(systemName: symbol).font(.system(size: prominent ? 23 : value == .shuffle ? 16 : 22, weight: .semibold))
                .foregroundStyle(shuffleActive ? Color(red: 0.12, green: 0.82, blue: 0.48) : .white.opacity(prominent ? 0.95 : value == .shuffle ? 0.5 : 0.95))
                .frame(width: prominent ? 46 : 30, height: 46)
                .background(prominent ? Color.white.opacity(0.08) : .clear, in: Circle())
                .overlay(alignment: .bottom) {
                    if shuffleActive { Circle().fill(Color(red: 0.12, green: 0.82, blue: 0.48)).frame(width: 4, height: 4).padding(.bottom, 2) }
                }
                .contentShape(Rectangle())
        }.buttonStyle(MusicControlStyle()).disabled(busy).help(title).accessibilityLabel(title)
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(min(86400 * 7, max(0, seconds.isFinite ? seconds : 0)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct MusicControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
