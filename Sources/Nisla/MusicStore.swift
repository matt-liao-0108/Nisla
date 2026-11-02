import AppKit
import SwiftUI
import AudioToolbox

enum MusicPlayer: String, CaseIterable, Identifiable, Sendable {
    case apple = "com.apple.Music"
    case spotify = "com.spotify.client"
    case netease = "com.netease.163music"
    case qq = "com.tencent.QQMusicMac"
    var id: String { rawValue }
    var title: String {
        switch self { case .apple: "Apple Music"; case .spotify: "Spotify"; case .netease: "网易云音乐"; case .qq: "QQ 音乐" }
    }
    var usesNowPlaying: Bool { self == .netease || self == .qq }
    var badgeColor: Color {
        switch self {
        case .apple: Color(red: 0.98, green: 0.25, blue: 0.36)
        case .spotify: Color(red: 0.12, green: 0.68, blue: 0.36)
        case .netease: Color(red: 0.90, green: 0.19, blue: 0.23)
        case .qq: Color(red: 0.12, green: 0.72, blue: 0.54)
        }
    }
}

enum MusicCommand: String, Sendable {
    case toggle = "toggle-play-pause", next = "next-track", previous = "previous-track"
    case shuffle = "toggle-shuffle"
    var script: String { switch self { case .toggle: "playpause"; case .next: "next track"; case .previous: "previous track"; case .shuffle: "set shuffle enabled to not shuffle enabled" } }
    var mediaRemoteID: String { switch self { case .toggle: "2"; case .next: "4"; case .previous: "5"; case .shuffle: "6" } }
}

struct MusicTrack: Sendable {
    let player: MusicPlayer
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let duration: Double
    let position: Double
    let artworkURL: URL?
    var artwork: Data? = nil
    var shuffleEnabled: Bool? = nil
    var updatedAt = Date()

    func elapsed(at date: Date) -> Double {
        let value = position + (playing ? max(0, date.timeIntervalSince(updatedAt)) : 0)
        return max(0, min(duration > 0 ? duration : value, value))
    }
}

enum MusicFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum NativeMusic {
    static func query(_ player: MusicPlayer) async throws -> MusicTrack? {
        guard !player.usesNowPlaying else { throw MusicFailure.message("此播放器需通过系统正在播放连接。") }
        return try await Task.detached(priority: .utility) {
            let cover = player == .spotify ? "artwork url of current track" : "\"\""
            let artworkScript = player == .apple ? """
                    set coverBytes to ""
                    try
                        set coverBytes to raw data of artwork 1 of current track
                    end try
            """ : "set coverBytes to \"\""
            let shuffleProperty = player == .spotify ? "shuffling" : "shuffle enabled"
            let script = """
            with timeout of 4 seconds
                if application id "\(player.rawValue)" is not running then return {}
                tell application id "\(player.rawValue)"
                    if player state is stopped then return {}
                    \(artworkScript)
                    set shuffleState to "unknown"
                    try
                        set shuffleState to \(shuffleProperty) as text
                    end try
                    return {name of current track, artist of current track, album of current track, player state as text, duration of current track, player position, \(cover), coverBytes, shuffleState}
                end tell
            end timeout
            """
            let result = try execute(script)
            var track = parseFields((1...min(7, max(1, result.numberOfItems))).map { result.atIndex($0)?.stringValue ?? "" }, player: player)
            if player == .apple, let data = result.atIndex(8)?.data, data.count < 8 * 1024 * 1024, NSImage(data: data) != nil { track?.artwork = data }
            track?.shuffleEnabled = parseShuffle(result.atIndex(9)?.stringValue)
            return track
        }.value
    }

    static func parseShuffle(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    static func parseFields(_ fields: [String], player: MusicPlayer) -> MusicTrack? {
        guard fields.count >= 6 else { return nil }
        func number(_ index: Int) -> Double {
            let value = Double(fields[index].replacingOccurrences(of: ",", with: ".")) ?? 0
            return value.isFinite ? max(0, value) : 0
        }
        let url = fields.count > 6 ? URL(string: fields[6]).flatMap { $0.scheme == "https" ? $0 : nil } : nil
        return MusicTrack(player: player, title: fields[0], artist: fields[1], album: fields[2], playing: fields[3] == "playing", duration: number(4) / (player == .spotify ? 1000 : 1), position: number(5), artworkURL: url)
    }

    static func control(_ command: MusicCommand, player: MusicPlayer) async throws {
        guard !player.usesNowPlaying else { throw MusicFailure.message("此播放器需通过系统正在播放控制。") }
        let action = command == .shuffle && player == .spotify ? "set shuffling to not shuffling" : command.script
        _ = try await Task.detached(priority: .utility) {
            _ = try execute("""
            with timeout of 4 seconds
                if application id "\(player.rawValue)" is not running then error "播放器已退出"
                tell application id "\(player.rawValue)" to \(action)
            end timeout
            """)
            return true
        }.value
    }

    private static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw MusicFailure.message("无法创建播放器控制脚本。") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                throw MusicFailure.message("自动化权限未允许：请在系统设置 → 隐私与安全性 → 自动化中允许 Nisla 控制所选播放器。")
            }
            throw MusicFailure.message("播放器接口不可用：\(error[NSAppleScript.errorMessage] as? String ?? "请确认播放器已打开并载入歌曲")")
        }
        return result
    }
}

@MainActor struct MusicBackend {
    var running: (MusicPlayer) -> Bool
    var queryNative: (MusicPlayer) async throws -> MusicTrack?
    var querySystem: () async throws -> MusicTrack?
    var controlNative: (MusicCommand, MusicPlayer) async throws -> Void
    var controlSystem: (MusicCommand, MusicTrack) async throws -> Void
    var volume: () -> Double? = { nil }

    static var live: Self {
        Self(running: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty },
             queryNative: { try await NativeMusic.query($0) }, querySystem: { try await NowPlayingBridge.query() },
             controlNative: { try await NativeMusic.control($0, player: $1) },
             controlSystem: { try await NowPlayingBridge.control($0, expected: $1) },
             volume: { SystemOutputVolume.read() })
    }
}

@MainActor final class MusicStore: ObservableObject {
    static let shared = MusicStore()
    @Published var enabled: Bool { didSet { preferences.set(enabled, forKey: "musicEnabled"); invalidate() } }
    @Published var selectedPlayer: String { didSet { preferences.set(selectedPlayer, forKey: "musicPlayer"); invalidate() } }
    @Published var remoteArtwork: Bool { didSet { preferences.set(remoteArtwork, forKey: "musicRemoteArtwork") } }
    @Published private(set) var track: MusicTrack?
    @Published private(set) var busy = false
    @Published private(set) var status = "音乐功能尚未启用"
    @Published private(set) var outputVolume: Double?
    private var generation = UUID()
    private var bridgeFailure: String?
    private let preferences: UserDefaults
    private let backend: MusicBackend

    init(preferences: UserDefaults = .standard, backend: MusicBackend? = nil) {
        self.preferences = preferences
        self.backend = backend ?? .live
        enabled = preferences.bool(forKey: "musicEnabled")
        let savedPlayer = preferences.string(forKey: "musicPlayer") ?? "auto"
        let supportedPlayer = MusicPlayer(rawValue: savedPlayer) == nil ? "auto" : savedPlayer
        selectedPlayer = supportedPlayer
        if supportedPlayer != savedPlayer { preferences.set(supportedPlayer, forKey: "musicPlayer") }
        preferences.removeObject(forKey: "musicHelper")
        remoteArtwork = preferences.object(forKey: "musicRemoteArtwork") == nil
            ? true : preferences.bool(forKey: "musicRemoteArtwork")
    }

    private func invalidate() {
        generation = UUID(); track = nil; bridgeFailure = nil; outputVolume = nil
        status = enabled ? "点击刷新读取播放器" : "音乐功能已关闭"
    }

    func refresh(automatic: Bool = false) async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false }
        let token = generation
        outputVolume = backend.volume()
        if !automatic { bridgeFailure = nil }
        let selected = MusicPlayer(rawValue: selectedPlayer)
        let candidates = (selected.map { [$0] } ?? MusicPlayer.allCases).filter(backend.running)
        var paused: MusicTrack?
        var failure: String?
        if candidates.contains(where: \.usesNowPlaying), bridgeFailure == nil {
            do {
                let current = try await backend.querySystem()
                guard generation == token, !Task.isCancelled else { return }
                if let current, current.player.usesNowPlaying, candidates.contains(current.player) {
                    if current.playing { track = current; status = "已连接 · \(current.player.title) · 系统正在播放"; return }
                    paused = current
                }
            } catch is CancellationError { return }
            catch {
                guard generation == token else { return }
                // A failed private API must not be retried continuously by the timer.
                bridgeFailure = error.localizedDescription
            }
        }
        for player in candidates where !player.usesNowPlaying {
            do {
                let current = try await backend.queryNative(player)
                guard generation == token, !Task.isCancelled else { return }
                if current?.playing == true { track = current; status = "已连接 · \(player.title)"; return }
                if paused == nil { paused = current }
            } catch {
                guard generation == token else { return }
                failure = error.localizedDescription
            }
        }
        guard generation == token else { return }
        track = paused
        if let paused { status = "已暂停 · \(paused.player.title)" }
        else if let error = bridgeFailure ?? failure { status = error }
        else if let selected, selected.usesNowPlaying {
            status = "请先在 \(selected.title) 播放歌曲，并确认 macOS 控制中心的“正在播放”显示此播放器。"
        } else { status = "请在 Apple Music、Spotify、网易云音乐或 QQ 音乐中播放歌曲。" }
    }

    func control(_ command: MusicCommand) async {
        guard enabled, !busy, let track else { return }
        busy = true
        let token = generation
        do {
            if track.player.usesNowPlaying {
                try await backend.controlSystem(command, track)
            } else { try await backend.controlNative(command, track.player) }
            if generation == token { status = "控制指令已发送" }
        } catch {
            if generation == token { self.track = nil; status = error.localizedDescription }
            busy = false
            return
        }
        busy = false
        if generation == token { await refresh() }
    }

    func open(_ player: MusicPlayer) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { status = "未安装 \(player.title)"; return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

enum SystemOutputVolume {
    // Read the current output device only. Never changes volume, mute or device routing.
    static func read() -> Double? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr, muted != 0 { return 0 }
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var level: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr, level.isFinite else { return nil }
        return Double(min(1, max(0, level)))
    }
}
