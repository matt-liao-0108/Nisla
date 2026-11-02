import Foundation

/// Opt-in local smoke check. Only initializes and performs the connection's
/// read-only metadata queries. Never resumes a thread or starts a model turn.
@main struct CodexConnectionSmoke {
    @MainActor static func main() async throws {
        guard let executable = ProcessInfo.processInfo.environment["NISLA_CODEX_SMOKE_PATH"], !executable.isEmpty else {
            print("SKIP: set NISLA_CODEX_SMOKE_PATH to explicitly enable a real local CLI connection check")
            return
        }
        let suite = "NislaConnectionSmoke-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set("direct", forKey: "codexTransport")
        let connection = CodexConnection(executableOverride: executable, preferences: prefs)
        defer { connection.disconnect(); prefs.removePersistentDomain(forName: suite) }
        connection.connect()
        for _ in 0..<150 {
            if connection.connected { break }
            if !connection.connecting { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard connection.connected else { throw CodexConnection.Failure(message: "Real CLI handshake failed: " + connection.status) }
        precondition(connection.transport == "direct")
        precondition(connection.activeTurns.isEmpty && connection.messages.isEmpty && !connection.sending)
        print("PASS: Nisla's real connection code completed initialize/initialized against the installed CLI; independent service only, no thread/resume or turn/start, no real preference changes")
    }
}
