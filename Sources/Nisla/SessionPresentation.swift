import Foundation

/// Classify provenance, never titles or message text: a user may name a normal
/// conversation "Guardian review". Unknown metadata remains visible.
enum SessionProvenance {
    static func classify(_ metadata: [String: Any]) -> (kind: CodexSessionKind?, parent: String?) {
        let source = metadata["source"] ?? metadata["thread_source"] ?? metadata["threadSource"]
        let subagent = (source as? [String: Any])?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let parent = (metadata["parent_thread_id"] ?? metadata["parentThreadId"] ?? spawn?["parent_thread_id"]) as? String
        let parentID = parent.flatMap { $0.isEmpty ? nil : $0 }
        if let source = source as? [String: Any], let subagent = source["subagent"] {
            let kind = (subagent as? [String: Any])?["other"] as? String ?? subagent as? String
            return (kind == "guardian" || kind == "review" ? .review : .subagent, parentID)
        }
        if let source = source as? String {
            if ["guardian", "review", "subagent_review"].contains(source) { return (.review, parentID) }
            if source == "subagent" || source.hasPrefix("subagent_") { return (.subagent, parentID) }
        }
        return (parentID == nil ? nil : .subagent, parentID)
    }

    static func read(_ url: URL) -> (kind: CodexSessionKind?, parent: String?) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? file.close() }
        var data = Data()
        // Only read the first metadata record, bounded even for malformed logs.
        while data.count < 2_097_152, let chunk = try? file.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if let newline = data.firstIndex(of: 10) { data = Data(data[..<newline]); break }
        }
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["type"] as? String == "session_meta", let metadata = row["payload"] as? [String: Any] else { return (nil, nil) }
        return classify(metadata)
    }

    static func enriched(_ session: CodexSession, local: [CodexSession]) -> CodexSession {
        guard let known = local.first(where: { $0.id == session.id }) else { return session }
        var value = session
        value.internalKind = value.internalKind ?? known.internalKind
        value.parentThreadID = value.parentThreadID ?? known.parentThreadID
        value.sourcePath = value.sourcePath ?? known.sourcePath
        return value
    }
}

/// Presentation only. A model's "allow" result is never an approval action.
struct ReviewSummary: Equatable {
    let risk: String
    let authorization: String
    let outcome: String
    let rationale: String
    static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 262_144, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let risk = value["risk_level"] as? String, ["low", "medium", "high", "unknown"].contains(risk),
              let authorization = value["user_authorization"] as? String,
              ["low", "medium", "high", "unknown"].contains(authorization),
              let outcome = value["outcome"] as? String, ["allow", "deny", "ask", "reject"].contains(outcome),
              let rationale = value["rationale"] as? String else { return nil }
        return Self(risk: risk, authorization: authorization, outcome: outcome, rationale: rationale)
    }
    var riskLabel: String { switch risk { case "low": "低风险"; case "medium": "中风险"; case "high": "高风险"; default: "风险未知" } }
    var outcomeLabel: String { switch outcome { case "allow": "允许"; case "deny", "reject": "拒绝"; default: "需确认" } }
    var authorizationLabel: String { switch authorization { case "low": "授权依据较弱"; case "medium": "部分授权"; case "high": "授权明确"; default: "授权未知" } }
}
