import Foundation
import SwiftUI

@main struct InterruptChecks {
    @MainActor static func wait(attempts: Int = 200, _ predicate: () -> Bool) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Fixture timed out")
    }

    @MainActor static func main() async throws {
        let defaults = UserDefaults(suiteName: "NislaInterrupt-" + UUID().uuidString)!
        let connection = CodexConnection(executableOverride: FileManager.default.currentDirectoryPath + "/Tests/mock_codex_interrupt.py", preferences: defaults)
        connection.connect()
        try await wait { connection.connected }
        connection.stop("idle")
        precondition(connection.stoppingThreads.isEmpty && !connection.canStop("idle"))

        connection.send("Stop before acknowledgement", to: "early")
        connection.stop("early")
        connection.stop("early")
        precondition(connection.stoppingThreads.contains("early"))
        try await wait { connection.activeTurns["early"] == "early-1" && !connection.sending }
        try await Task.sleep(for: .milliseconds(40))
        precondition(connection.activeTurns["early"] != nil && connection.stoppingThreads.contains("early"), "Acknowledgement is not completion")
        connection.stop("early")
        try await wait { connection.activeTurns["early"] == nil }
        precondition(connection.conversations["early"]?.last?.state == .interrupted)
        precondition(connection.conversations["early"]?.last?.text == "Partial reply")
        precondition(connection.conversations["early"]?.first?.text == "Stop before acknowledgement")
        precondition(connection.stoppingThreads.isEmpty)
        print("PASS: stop before start response, exact turn ID, duplicate clicks blocked, wait for completion, preserve partial text")

        connection.send("A second turn", to: "early")
        try await wait { connection.activeTurns["early"] == "early-2" }
        try await Task.sleep(for: .milliseconds(30))
        precondition(connection.activeTurns["early"] == "early-2", "Old completion must not clear a newer turn")
        precondition(connection.conversations["early"]?.last?.state == .streaming)
        connection.stop("early")
        try await wait { connection.activeTurns["early"] == nil }
        precondition(connection.conversations["early"]?.count == 4)
        precondition(connection.conversations["early"]?.last?.text == "Partial reply", "Late deltas must not resurrect interrupted output")
        print("PASS: old completion and late deltas cannot alter a new turn; follow-up after interruption works")

        connection.send("Retry stop", to: "retry")
        try await wait { connection.activeTurns["retry"] != nil && !connection.sending }
        connection.stop("retry")
        try await wait { connection.stopErrors["retry"] != nil }
        precondition(connection.activeTurns["retry"] != nil && connection.canStop("retry"))
        precondition(!connection.stoppingThreads.contains("retry"))
        connection.stop("retry")
        try await wait { connection.activeTurns["retry"] == nil }
        precondition(connection.stopErrors["retry"] == nil)
        precondition(connection.conversations["retry"]?.last?.state == .interrupted)
        connection.send("No completion event", to: "unconfirmed")
        try await wait { connection.activeTurns["unconfirmed"] != nil && !connection.sending }
        connection.stop("unconfirmed")
        try await wait(attempts: 1500) { connection.stopErrors["unconfirmed"] != nil }
        precondition(connection.activeTurns["unconfirmed"] != nil && connection.canStop("unconfirmed"))
        precondition(connection.conversations["unconfirmed"]?.last?.state == .streaming)
        print("PASS: missing completion confirmation times out with a retryable warning, without falsely reporting stopped")
        connection.disconnect()
        precondition(connection.stoppingThreads.isEmpty && connection.sendingThreads.isEmpty)
        print("PASS: rejected interruption stays running, explains failure, permits explicit retry, clears state on disconnect")
    }
}
