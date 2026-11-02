import Foundation

@main struct MusicChecks {
    @MainActor static func main() async throws {
        precondition(MusicPlayer.allCases.count == 4)
        precondition(MusicPlayer(rawValue: "com.netease.163music") == .netease)
        precondition(MusicPlayer(rawValue: "com.tencent.QQMusicMac") == .qq)
        precondition(MusicPlayer.netease.usesNowPlaying && MusicPlayer.qq.usesNowPlaying && !MusicPlayer.apple.usesNowPlaying)
        print("PASS: four players have explicit native or Now Playing routing")
        let spotify = NativeMusic.parseFields(["Song", "Artist", "Album", "playing", "240000", "12.5", "https://example.com/cover.png"], player: .spotify)!
        precondition(spotify.duration == 240 && spotify.position == 12.5 && spotify.artworkURL?.scheme == "https")
        precondition(spotify.elapsed(at: spotify.updatedAt.addingTimeInterval(2)) == 14.5)
        precondition(spotify.elapsed(at: spotify.updatedAt.addingTimeInterval(1000)) == 240)
        let apple = NativeMusic.parseFields(["Song", "Artist", "Album", "paused", "240", "12,5", "file:///private/test"], player: .apple)!
        precondition(apple.duration == 240 && apple.position == 12.5 && !apple.playing && apple.artworkURL == nil)
        precondition(apple.elapsed(at: apple.updatedAt.addingTimeInterval(10)) == 12.5)
        precondition(NativeMusic.parseFields([], player: .apple) == nil)
        print("PASS: native player units, paused progress, locale decimals and HTTPS-only artwork")
        precondition(MusicCommand.next.rawValue == "next-track" && MusicCommand.previous.script == "previous track")
        precondition(MusicCommand.shuffle.mediaRemoteID == "6" && MusicCommand.shuffle.script.contains("shuffle enabled"))
        let preferences = UserDefaults(suiteName: "IslandMusicChecks-" + UUID().uuidString)!
        let store = MusicStore(preferences: preferences)
        precondition(store.remoteArtwork)
        store.remoteArtwork = false
        precondition(!MusicStore(preferences: preferences).remoteArtwork)
        store.remoteArtwork = true
        precondition(MusicStore(preferences: preferences).remoteArtwork)
        print("PASS: network artwork defaults on; explicit off/on preferences persist")
        precondition(!store.enabled && store.track == nil)
        await store.refresh()
        await store.control(.toggle)
        precondition(!store.busy && store.track == nil)
        print("PASS: music is opt-in and disabled refresh/control never contacts a player")
        preferences.set("com.netease.163music", forKey: "musicPlayer")
        preferences.set("/fixture/deprecated", forKey: "musicHelper")
        let migrated = MusicStore(preferences: preferences)
        precondition(migrated.selectedPlayer == MusicPlayer.netease.rawValue)
        precondition(preferences.string(forKey: "musicPlayer") == MusicPlayer.netease.rawValue)
        precondition(preferences.object(forKey: "musicHelper") == nil)
        print("PASS: NetEase selection persists; obsolete external helper configuration is removed")
        let payload = Data(#"{"bundleIdentifier":"com.netease.163music","title":"Fixture Song","artist":"Fixture Artist","playing":true,"duration":240,"elapsedTime":12,"elapsedTimeNow":14}"#.utf8)
        let netease = try NowPlayingBridge.parse(payload)!
        precondition(netease.player == .netease && netease.position == 14 && netease.duration == 240)
        let qq = try NowPlayingBridge.parse(Data(#"{"bundleIdentifier":"com.tencent.QQMusicMac.helper","parentApplicationBundleIdentifier":"com.tencent.QQMusicMac","title":"QQ Fixture","playing":false,"elapsedTime":20,"elapsedTimeNow":40,"duration":-1,"artworkData":"invalid"}"#.utf8))!
        precondition(qq.player == .qq && !qq.playing && qq.duration == 0 && qq.position == 20 && qq.artwork == nil)
        precondition(qq.elapsed(at: qq.updatedAt.addingTimeInterval(20)) == 20)
        let emptySystem = try NowPlayingBridge.parse(Data("null".utf8))
        let browserSystem = try NowPlayingBridge.parse(Data(#"{"bundleIdentifier":"com.browser","title":"Other"}"#.utf8))
        precondition(emptySystem == nil && browserSystem == nil)
        precondition(!NowPlayingBridge.sameTarget(netease, qq))
        print("PASS: system source filtering, helper parent IDs, seconds, paused progress and bad artwork")

        var reads = 0, controls = 0, fail = false
        var reported: MusicTrack? = netease
        let fake = MusicBackend(running: { _ in true }, queryNative: { _ in apple }, querySystem: {
            reads += 1
            if fail { throw MusicFailure.message("fixture failure") }
            return reported
        }, controlNative: { _, _ in controls += 1 }, controlSystem: { _, _ in controls += 1 })
        let isolated = UserDefaults(suiteName: "IslandMusicBackendChecks-" + UUID().uuidString)!
        let routed = MusicStore(preferences: isolated, backend: fake)
        await routed.refresh()
        precondition(reads == 0)
        routed.enabled = true
        await routed.refresh()
        precondition(routed.track?.player == .netease)
        await routed.control(.next)
        precondition(controls == 1)
        routed.selectedPlayer = MusicPlayer.qq.rawValue
        await routed.refresh()
        precondition(routed.track == nil)
        reported = qq
        await routed.refresh()
        precondition(routed.track?.player == .qq)
        fail = true
        await routed.refresh()
        let failedReads = reads
        await routed.refresh(automatic: true)
        precondition(reads == failedReads && routed.track == nil)
        await routed.refresh()
        precondition(reads == failedReads + 1)
        routed.selectedPlayer = MusicPlayer.apple.rawValue
        await routed.refresh()
        precondition(routed.track?.player == .apple)
        precondition(reads == failedReads + 1)
        print("PASS: opt-in, system/native routing, selected-source mismatch, failure retry gate and native fallback")

        let fixture = try await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "print qq({\\\"bundleIdentifier\\\":\\\"com.tencent.QQMusicMac\\\",\\\"title\\\":\\\"Fixture\\\",\\\"playing\\\":true});"])
        let fixtureTrack = try NowPlayingBridge.parse(fixture)
        precondition(fixtureTrack?.player == .qq)
        do {
            _ = try await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "sleep 20"], timeout: 0.1)
            preconditionFailure("timeout must fail")
        } catch { precondition(error.localizedDescription.contains("超时")) }
        let cancelled = Task {
            try await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "sleep 20"])
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancel must fail") }
        catch { precondition(error is CancellationError) }
        do {
            _ = try await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "exit 1"])
            preconditionFailure("nonzero exit must fail")
        } catch { precondition(error.localizedDescription.contains("不可用")) }
        print("PASS: bounded subprocess output and timeout cleanup (fixture only, no real media commands)")
        for source in ["$SIG{TERM} = 'IGNORE'; sleep 20", "if (fork() == 0) { sleep 1; exit 0 }; exit 0"] {
            let began = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", source], timeout: 0.1)
                preconditionFailure("unresponsive helper must time out")
            } catch { precondition(error.localizedDescription.contains("超时")) }
            precondition(ProcessInfo.processInfo.systemUptime - began < 0.8)
        }
        do {
            _ = try await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: ["-e", "print 'x' x (12 * 1024 * 1024 + 1)"])
            preconditionFailure("oversized output must fail")
        } catch { precondition(error.localizedDescription.contains("过大")) }
        print("PASS: timeout remains bounded for ignored TERM and inherited stdout; oversized output is stopped")
    }
}
