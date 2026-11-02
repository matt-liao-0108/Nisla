import AppKit
import Foundation
import Darwin

/// Bundled BSD-licensed adapter. No Homebrew, external executable path or network service.
enum NowPlayingBridge {
    static func query() async throws -> MusicTrack? {
        let data = try await invoke(["get", "--now"])
        return try parse(data)
    }

    static func control(_ command: MusicCommand, expected: MusicTrack) async throws {
        // MediaRemote targets the system's active player, not a named application.
        // Refuse a stale UI rather than sending a command to a different source.
        guard let current = try await query(), sameTarget(current, expected) else {
            throw MusicFailure.message("系统正在播放来源已变化，请刷新后重试；未发送控制指令。")
        }
        _ = try await invoke(["send", command.mediaRemoteID])
    }

    static func sameTarget(_ lhs: MusicTrack, _ rhs: MusicTrack) -> Bool {
        lhs.player == rhs.player && lhs.title == rhs.title && lhs.artist == rhs.artist
    }

    static func parse(_ data: Data) throws -> MusicTrack? {
        guard data.count <= 12 * 1024 * 1024 else { throw MusicFailure.message("系统播放信息过大。") }
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        guard !(object is NSNull) else { return nil }
        guard let fields = object as? [String: Any] else { throw MusicFailure.message("系统播放信息格式不正确。") }
        let identifiers = [fields["parentApplicationBundleIdentifier"] as? String, fields["bundleIdentifier"] as? String].compactMap { $0 }
        guard let player = identifiers.compactMap(MusicPlayer.init(rawValue:)).first,
              let title = fields["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func number(_ key: String) -> Double {
            let value = (fields[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? max(0, value) : 0
        }
        let playing = (fields["playing"] as? Bool) ?? false
        var artwork: Data?
        if let encoded = fields["artworkData"] as? String, encoded.utf8.count <= 11 * 1024 * 1024,
           let bytes = Data(base64Encoded: encoded), bytes.count <= 8 * 1024 * 1024, NSImage(data: bytes) != nil {
            artwork = bytes
        }
        // --now already extrapolates the timestamp; do not extrapolate it twice.
        let position = playing && fields["elapsedTimeNow"] is NSNumber ? number("elapsedTimeNow") : number("elapsedTime")
        return MusicTrack(player: player, title: title, artist: fields["artist"] as? String ?? "",
                          album: fields["album"] as? String ?? "", playing: playing,
                          duration: number("duration"), position: position, artworkURL: nil, artwork: artwork)
    }

    private static func invoke(_ arguments: [String]) async throws -> Data {
        let bundle = Bundle.main.bundleURL
        let script = bundle.appendingPathComponent("Contents/Resources/MediaRemote/mediaremote-adapter.pl")
        let framework = bundle.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.appendingPathComponent("MediaRemoteAdapter").path) else {
            throw MusicFailure.message("请运行新版打包后的 Nisla.app；当前缺少内置系统音乐组件。")
        }
        return try await run(program: URL(fileURLWithPath: "/usr/bin/perl"), arguments: [script.path, framework.path] + arguments)
    }

    // Injectable executable only for hermetic process tests; UI never accepts an arbitrary path.
    static func run(program: URL, arguments: [String], timeout: Double = 6) async throws -> Data {
        let invocation = MediaInvocation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try invocation.run(program: program, arguments: arguments, timeout: timeout)
            }.value
        } onCancel: { invocation.cancel() }
    }
}

private final class MediaInvocation: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    func cancel(timeout: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        timedOut = timedOut || timeout
        // These are owned, read-only query helpers. A helper that ignores TERM
        // must not leave music controls or Bluetooth enrichment stuck forever.
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    func run(program: URL, arguments: [String], timeout: Double) throws -> Data {
        let output = Pipe()
        process.executableURL = program
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch {
            lock.unlock()
            throw MusicFailure.message("无法启动内置系统音乐组件，请重新安装完整的 Nisla.app。")
        }
        lock.unlock()
        output.fileHandleForWriting.closeFile()
        let deadline = DispatchWorkItem { [weak self] in self?.cancel(timeout: true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel(); output.fileHandleForReading.closeFile() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { break }
            // Poll instead of blocking on EOF: a helper's child can inherit
            // stdout even after the parent has exited or been cancelled.
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 50)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                cancel(); break
            }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                cancel(); break
            }
            if data.count + count > 12 * 1024 * 1024 {
                cancel(); process.waitUntilExit()
                throw MusicFailure.message("系统播放信息过大，已停止读取。")
            }
            data.append(contentsOf: bytes.prefix(count))
        }
        process.waitUntilExit()
        lock.lock()
        let wasCancelled = cancelled, wasTimedOut = timedOut
        lock.unlock()
        if wasTimedOut { throw MusicFailure.message("读取系统播放信息超时，请检查播放器后手动重试。") }
        if wasCancelled { throw CancellationError() }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw MusicFailure.message("系统音乐组件不可用，可能与当前 macOS 版本不兼容；Apple Music / Spotify 仍可使用直接连接。")
        }
        return data
    }
}
