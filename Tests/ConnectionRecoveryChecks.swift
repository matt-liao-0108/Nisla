import Foundation

@main struct ConnectionRecoveryChecks {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Connection recovery condition timed out")
    }
    @MainActor static func main() async throws {
        precondition(CodexLaunch.arguments(mode: "direct", socket: "/ignored") == ["app-server"])
        precondition(CodexLaunch.arguments(mode: "proxy", socket: " \n") == ["app-server", "proxy"])
        precondition(CodexLaunch.arguments(mode: "proxy", socket: " ~/fixture.sock \n").last == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("fixture.sock").path)
        func reason(_ value: String) -> CodexStartupFailure { CodexStartupFailure.classify(Data(value.utf8)) }
        precondition(reason("failed to connect to socket: Connection refused (os error 61)") == .unavailableSocket)
        precondition(reason("error: unrecognized subcommand 'app-server'") == .unsupportedServer)
        precondition(reason("TOML parse error: fixture") == .configuration)
        precondition(reason("Permission denied (os error 13)") == .permission)
        precondition(reason("unexpected opaque data") == .unknown)
        let suite = "NislaConnectionRecovery-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/mock_codex_recovery.py"
        let connection = CodexConnection(executableOverride: fixture, preferences: prefs)
        connection.connectIndependently()
        precondition(connection.transport == "proxy" && !connection.connecting, "Recovery requires an explicit offered action")
        connection.connect()
        try await waitFor { connection.canOfferDirectConnection }
        precondition(!connection.connected && !connection.connecting && connection.transport == "proxy")
        precondition(connection.status.contains("Socket"))
        precondition(!connection.diagnostics.joined().contains("private-fixture") && !connection.diagnostics.joined().contains("token-secret"))
        let count = connection.diagnostics.count
        try await Task.sleep(for: .milliseconds(200))
        precondition(connection.diagnostics.count == count, "Late disconnect callbacks must not overwrite the real failure")
        connection.connectIndependently()
        try await waitFor { connection.connected && connection.sessions.count == 1 }
        precondition(connection.transport == "direct" && connection.status.contains("独立"))
        precondition(connection.messages.isEmpty && connection.activeTurns.isEmpty && connection.requests.isEmpty)
        connection.follow("recovery-thread")
        try await waitFor { !connection.checkingThreads.contains("recovery-thread") }
        precondition(connection.threadErrors["recovery-thread"] == nil)
        connection.disconnect()
        precondition(!connection.canOfferDirectConnection)
        connection.transport = "proxy"; connection.socket = "unsupported"
        connection.connect()
        try await waitFor { connection.canOfferDirectConnection }
        precondition(connection.status.contains("不支持共享服务代理"))
        connection.disconnect()
        connection.socket = "permission"; connection.connect()
        try await waitFor { connection.status.contains("访问本地文件或 Socket 被拒绝") }
        precondition(!connection.canOfferDirectConnection)
        connection.disconnect()
        connection.socket = ""; connection.connect(); connection.disconnect()
        try await Task.sleep(for: .milliseconds(300))
        precondition(!connection.canOfferDirectConnection && !connection.connected && !connection.connecting)
        precondition(connection.status == "未连接：本地日志监控仍可使用")
        let capture = CodexStartupCapture()
        capture.append(Data(repeating: 120, count: 100_000))
        capture.append(Data("failed to connect to socket: No such file or directory".utf8))
        precondition(capture.failure == .unavailableSocket)
        print("PASS: missing/refused socket, unsupported proxy/server, permission/configuration errors, explicit-only recovery, compatible stdio startup, stable failure status, cancellation, bounded private diagnostics and isolated preferences; fake services only")
    }
}
