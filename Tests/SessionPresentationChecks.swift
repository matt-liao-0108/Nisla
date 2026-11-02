import Foundation
import AppKit

@main struct SessionPresentationChecks {
    @MainActor static func main() throws {
        let guardian: [String: Any] = ["source": ["subagent": ["other": "guardian"]], "parent_thread_id": "main"]
        precondition(SessionProvenance.classify(guardian).kind == .review)
        precondition(SessionProvenance.classify(guardian).parent == "main")
        precondition(SessionProvenance.classify(["source": ["subagent": ["thread_spawn": ["parent_thread_id": "main"]]]]).kind == .subagent)
        precondition(SessionProvenance.classify(["source": ["subagent": ["thread_spawn": ["parent_thread_id": "main"]]]]).parent == "main")
        precondition(SessionProvenance.classify(["source": "vscode", "name": "Guardian review"]).kind == nil)
        precondition(SessionProvenance.classify(["source": "future-client"]).kind == nil)
        precondition(SessionProvenance.classify(["source": "subagent_review"]).kind == .review)
        precondition(SessionProvenance.classify(["parentThreadId": "main"]).kind == .subagent)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NislaSessions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("fixture.jsonl")
        var meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": guardian])
        meta.append(10)
        meta.append(Data("not metadata and deliberately malformed".utf8))
        try meta.write(to: log)
        precondition(SessionProvenance.read(log).kind == .review)
        try Data("broken".utf8).write(to: log)
        precondition(SessionProvenance.read(log).kind == nil)

        let sessionsFolder = folder.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
        for index in 0..<105 {
            try meta.write(to: sessionsFolder.appendingPathComponent("guardian\(index).jsonl"))
        }
        let mainLog = sessionsFolder.appendingPathComponent("main.jsonl")
        try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["source": "vscode"]]).write(to: mainLog)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1000)], ofItemAtPath: mainLog.path)
        let discovered = PinStore.scanCodex(home: folder)
        precondition(discovered.filter { $0.internalKind == nil }.map(\.id) == ["main"],
            "Recent internal tasks must not exhaust the normal conversation scan limit")
        precondition(discovered.filter { $0.internalKind != nil }.count == 100)

        let main = CodexSession(id: "main", title: "Guardian review", project: "Fixture", modifiedAt: .now, isRunning: false)
        let review = CodexSession(id: "review", title: "Guardian review", project: "Fixture", modifiedAt: .now,
            isRunning: false, internalKind: .review, parentThreadID: "main")
        let child = CodexSession(id: "child", title: "Child", project: "Fixture", modifiedAt: .now,
            isRunning: false, internalKind: .subagent)
        let store = PinStore(storageDirectory: folder,
            preferences: UserDefaults(suiteName: "NislaSessions-" + UUID().uuidString)!, interactive: false)
        store.codexSessions = [review, main, child]
        store.showRecentSessions = true
        precondition(store.visibleCodexSessions.map(\.id) == ["main"])
        store.showInternalCodexSessions = true
        precondition(store.visibleCodexSessions.count == 3)
        store.pinnedSessions = [review, main]; store.showRecentSessions = false
        store.showInternalCodexSessions = false
        precondition(store.visibleCodexSessions.map(\.id) == ["main"])
        precondition(store.pinnedSessions.count == 2, "Filtering must not delete pins")
        var serverReview = review; serverReview.internalKind = nil; serverReview.parentThreadID = nil
        store.connectedCodexSessions = [serverReview, main]; store.showRecentSessions = true
        precondition(store.visibleCodexSessions.map(\.id) == ["main"], "Local provenance must enrich older server responses")
        store.connectedCodexSessions = [serverReview]
        precondition(store.visibleCodexSessions.map(\.id) == ["main"], "An internal-only server page must not hide local main conversations")
        let old = try JSONEncoder().encode(main)
        let decoded = try JSONDecoder().decode(CodexSession.self, from: old)
        precondition(decoded.internalKind == nil)

        let raw = #"{"risk_level":"low","user_authorization":"high","outcome":"allow","rationale":"只读检查\n未修改数据"}"#
        let summary = ReviewSummary.parse(raw)!
        precondition(summary.riskLabel == "低风险" && summary.outcomeLabel == "允许")
        precondition(summary.rationale == "只读检查\n未修改数据")
        precondition(ReviewSummary.parse("ordinary conversation") == nil)
        precondition(ReviewSummary.parse(#"{"outcome":"allow"}"#) == nil)
        precondition(ReviewSummary.parse(raw.replacingOccurrences(of: "low", with: "future-value")) == nil)
        precondition(ReviewSummary.parse(String(repeating: "a", count: 262_145)) == nil)
        print("PASS: provenance-only classification, internal-session filtering and opt-in display, pinned-data preservation, server enrichment, legacy decoding, safe review summaries and malformed-input fallback; fixture data only")
    }
}
