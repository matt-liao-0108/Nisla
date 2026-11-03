import Foundation
@main struct CursorChecks {
    @MainActor static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<250 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        preconditionFailure("Cursor fixture timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NislaCursor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "NislaCursorChecks-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/mock_cursor_acp.py"
        let c = CursorConnection(executableOverride: fixture, preferences: prefs)
        c.workspace = root.path
        c.connect(); try await wait { c.connected }
        precondition(c.supportsLoad && c.sessions.isEmpty, "Connecting must not create or send a task")
        var session: CursorSession?
        c.newSession { session = $0 }; try await wait { session != nil }
        let id = session!.id
        precondition(c.loadedSessions.contains(id))
        c.send("flow", to: id)
        precondition(c.conversations[id]?.map(\.role) == [.user, .assistant], "Show prompt and waiting state immediately")
        try await wait { c.permissions.count == 1 }
        precondition(c.conversations[id]?.last?.text == "你好 Cursor")
        precondition(c.conversations[id]?.count == 2, "Prompt echoes must not duplicate user messages")
        c.send("duplicate", to: id); precondition(c.conversations[id]?.count == 2)
        let permission = c.permissions[0]
        c.choose(permission, optionID: "forever"); precondition(c.permissions.count == 1, "No automatic/persistent approvals")
        c.choose(permission, optionID: "forged"); precondition(c.permissions.count == 1)
        c.choose(permission, optionID: "deny")
        try await wait { c.permissions.first?.method == "cursor/ask_question" }
        c.respond(c.permissions[0], result: ["outcome":"answered", "answers":[["questionId":"q", "selectedOptionIds":["one"]]]])
        try await wait { c.permissions.first?.method == "cursor/create_plan" }
        c.respond(c.permissions[0], result: ["outcome":"rejected"])
        try await wait { c.activeSessionID == nil }
        precondition(c.conversations[id]?.last?.state == .complete && c.conversations[id]?.last?.text == "你好 Cursor done")
        c.send("cancel", to: id); try await wait { !c.permissions.isEmpty }
        c.stop(); try await wait { c.activeSessionID == nil }
        precondition(!c.stopping && c.permissions.isEmpty && c.conversations[id]?.last?.state == .interrupted)
        c.send("unknown", to: id); try await wait { c.activeSessionID == nil }
        precondition(c.conversations[id]?.last?.text == "Unsupported request rejected")
        c.send("error", to: id); try await wait { c.activeSessionID == nil }
        precondition(c.error == "fixture-prompt-denied" && c.conversations[id]?.last?.state == .failed)
        c.send("long", to: id); try await wait { c.activeSessionID == nil }
        precondition(c.conversations[id]?.last?.text.count == 65_536)
        c.send("disconnect", to: id); try await wait { !c.permissions.isEmpty }
        c.disconnect()
        precondition(!c.connected && c.loadedSessions.isEmpty && c.permissions.isEmpty && c.activeSessionID == nil)
        precondition(c.conversations[id]?.last?.state == .interrupted)
        let restored = CursorConnection(executableOverride: fixture, preferences: prefs)
        precondition(restored.sessions.count == 1 && restored.conversations.isEmpty)
        restored.connect(); try await wait { restored.connected }
        restored.load(restored.sessions[0]); try await wait { restored.loadedSessions.contains(id) }
        precondition(restored.conversations[id]?.map(\.text) == ["Saved user","Saved assistant"], "Replay must omit thought chunks")
        restored.disconnect()
        for scenario in ["auth-fail", "bad-version", "no-load"] {
            let directory = root.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let test = CursorConnection(executableOverride: fixture, preferences: prefs)
            test.workspace = directory.path; test.connect()
            if scenario == "no-load" {
                try await wait { test.connected }; precondition(!test.supportsLoad)
                test.load(test.sessions[0]); precondition(!test.loadingSession)
            } else { try await wait { test.error != nil }; precondition(!test.connected && !test.connecting) }
            test.disconnect()
        }
        precondition(CursorConnection.directory(root.appendingPathComponent("missing").path) == nil)
        print("PASS: Cursor ACP handshake/auth, session creation/load/replay, streaming and UTF-8 fragments, permission rejection and questions/plans, unknown request rejection, cancellation, failure/disconnect states, bounded content, isolated persistence, incompatible versions; fake services only")
    }
}
