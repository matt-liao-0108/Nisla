import Foundation
import SwiftUI

@main struct AgentChecks {
    @MainActor static func main() async throws {
        let installed = CodexExecutableLocator.resolve(configured: "/old/codex", candidates: ["/new/codex"], executable: { $0 == "/new/codex" })
        precondition(installed == "/new/codex")
        precondition(CodexExecutableLocator.resolve(configured: "/custom/codex", candidates: ["/new/codex"], executable: { _ in true }) == "/custom/codex")
        print("PASS: missing CLI paths can fall back to an installed executable while preserving a valid custom path")
        let fixture = FileManager.default.currentDirectoryPath + "/Tests/mock_codex_server.py"
        let connection = CodexConnection(executableOverride: fixture)
        connection.connect()
        for _ in 0..<100 {
            if connection.sessions.count == 1 && connection.quota.contains("75%") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(connection.connected)
        precondition(connection.sessions.first?.id == "fixture-thread")
        precondition(connection.quota.contains("75%"))
        connection.send("Fixture input", to: "fixture-thread")
        precondition(connection.conversations["fixture-thread"]?.first?.text == "Fixture input")
        precondition(connection.conversations["fixture-thread"]?.first?.state == .sending)
        precondition(connection.conversations["fixture-thread"]?.last?.state == .waiting,
            "User text and a waiting indicator must be visible before network acknowledgement")
        for _ in 0..<100 {
            if !connection.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(connection.lastSendSucceeded)
        precondition(connection.lastSentThreadID == "fixture-thread" && connection.lastSentText == "Fixture input")
        precondition(connection.messages["fixture-thread"] == "Fixture reply")
        precondition(connection.conversations["fixture-thread"]?.last?.text == "Fixture reply")
        precondition(connection.conversations["fixture-thread"]?.last?.state == .streaming)
        precondition(connection.activeTurns["fixture-thread"] == "fixture-turn")
        let approval = connection.requests.first!
        connection.respond(approval, result: ["decision": "decline"])
        for _ in 0..<100 {
            if connection.activeTurns.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(connection.requests.isEmpty && connection.activeTurns.isEmpty)
        precondition(connection.conversations["fixture-thread"]?.last?.state == .complete)
        connection.send("Second input", to: "fixture-thread")
        precondition(connection.conversations["fixture-thread"]?.count == 4, "Sending again must preserve the prior exchange")
        precondition(connection.conversations["fixture-thread"]?[1].text == "Fixture reply")
        for _ in 0..<100 {
            if !connection.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        connection.respond(connection.requests.first!, result: ["decision": "decline"])
        for _ in 0..<100 {
            if connection.activeTurns.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        connection.send("Rejected input", to: "rejected-send")
        for _ in 0..<100 {
            if connection.conversations["rejected-send"]?.first?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(connection.conversations["rejected-send"]?.first?.text == "Rejected input")
        precondition(connection.conversations["rejected-send"]?.last?.state == .failed && !connection.lastSendSucceeded)
        print("PASS: optimistic user messages, waiting/streaming/completion, preserved exchanges and explicit send failure")
        connection.follow("occupied-thread")
        for _ in 0..<100 {
            if connection.threadErrors["occupied-thread"] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(connection.threadErrors["occupied-thread"]?.contains("占用") == true)
        precondition(connection.threadErrors["fixture-thread"] == nil)
        connection.send("Must not send", to: "occupied-thread")
        precondition(!connection.sending)
        precondition(connection.conversations["occupied-thread"] == nil)
        print("PASS: occupied thread explains read-only mode and blocks send without affecting other threads")
        connection.follow("long-thread")
        for _ in 0..<100 {
            if connection.messages["long-thread"] != nil && connection.quota.contains("100%") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(connection.messages["long-thread"]?.count == 65_536)
        precondition(connection.conversations["long-thread"]?.last?.text.count == 65_536)
        precondition(connection.quota.contains("100%"))
        print("PASS: long streams have a bounded UI buffer and out-of-range quota values cannot overflow")
        connection.disconnect()
        precondition(connection.threadErrors.isEmpty && connection.checkingThreads.isEmpty)
        precondition(!connection.connected)
        precondition(connection.sessions.isEmpty && connection.messages.isEmpty)
        precondition(connection.conversations["fixture-thread"]?.first?.text == "Fixture input")
        precondition(connection.conversations["long-thread"]?.last?.state == .interrupted)
        print("PASS: initialize, list, quota, resume, send, stream, explicit approval response, complete, disconnect")
        let failurePath = FileManager.default.currentDirectoryPath + "/Tests/mock_codex_failure.py"
        let rejected = CodexConnection(executableOverride: failurePath)
        rejected.connect()
        for _ in 0..<100 {
            if rejected.status.contains("fixture-handshake-denied") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(!rejected.connected && rejected.status.contains("fixture-handshake-denied"))
        let count = rejected.diagnostics.count
        try await Task.sleep(for: .milliseconds(200))
        precondition(rejected.diagnostics.count == count)
        rejected.disconnect()
        print("PASS: rejected initialization stops the process and removes its stream handlers")
    }
}
