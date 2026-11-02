import Foundation

struct ConversationHistoryMessage: Identifiable, Equatable, Sendable {
    let offset: UInt64
    let role: String
    let text: String
    var id: String { "log-\(offset)-\(role)" }
}

enum ConversationHistoryReader {
    enum Format: Sendable { case responses, events }
    struct Revision: Equatable, Sendable { let size: UInt64; let modified: Date }
    struct Page: Sendable {
        var messages: [ConversationHistoryMessage] = []
        var before: UInt64 = 0
        var format: Format = .responses
        var unavailable = false
    }

    static func revision(path: String) -> Revision? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else { return nil }
        return Revision(size: size.uint64Value, modified: date)
    }

    /// Read a bounded window backwards. No resume, writer lock, or service is
    /// involved; ignore the incomplete final JSON record while Codex appends.
    static func page(path: String, before: UInt64? = nil, format: Format? = nil,
                     limit: Int = 24, byteBudget: Int = 4_194_304) -> Page {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return Page(unavailable: true) }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return Page(unavailable: true) }
        let end = min(before ?? length, length)
        let budget = UInt64(min(4_194_304, max(1024, byteBudget)))
        let start = end > budget ? end - budget : 0
        do {
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: Int(end - start)) ?? Data()
            var responses: [ConversationHistoryMessage] = [], events: [ConversationHistoryMessage] = []
            for line in data.split(separator: 10) {
                if start > 0 && line.startIndex == 0 { continue }
                if line.endIndex == data.endIndex && data.last != 10 { continue }
                guard line.count <= 1_048_576,
                      let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = row["payload"] as? [String: Any] else { continue }
                let offset = start + UInt64(line.startIndex)
                if row["type"] as? String == "response_item", payload["type"] as? String == "message",
                   let role = payload["role"] as? String, ["user", "assistant"].contains(role),
                   let content = payload["content"] as? [[String: Any]] {
                    let text = content.compactMap { block -> String? in
                        guard ["input_text", "output_text", "text"].contains(block["type"] as? String ?? ""),
                              let text = block["text"] as? String, !isContext(text) else { return nil }
                        return text
                    }.joined(separator: "\n")
                    if !text.isEmpty { responses.append(.init(offset: offset, role: role, text: String(text.prefix(65_536)))) }
                } else if row["type"] as? String == "event_msg",
                          let type = payload["type"] as? String, ["user_message", "agent_message"].contains(type),
                          let text = payload["message"] as? String, !text.isEmpty, !isContext(text) {
                    events.append(.init(offset: offset, role: type == "user_message" ? "user" : "assistant", text: String(text.prefix(65_536))))
                }
            }
            // Pick one record family so duplicate event/response messages do
            // not appear twice. Carry this format across older pages.
            let selected = format ?? (responses.isEmpty && !events.isEmpty ? .events : .responses)
            let messages = Array((selected == .responses ? responses : events).suffix(min(48, max(1, limit))))
            let firstCompleteLine = data.firstIndex(of: 10).map { start + UInt64($0) + 1 } ?? start
            let cursor = messages.first?.offset ?? (start == 0 ? 0 : min(end - 1, firstCompleteLine))
            return Page(messages: messages, before: cursor, format: selected)
        } catch { return Page(unavailable: true) }
    }

    private static func isContext(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<environment_context>", "<external_codex_apps_open_page>", "<send_user_message_question_reply>",
                "<permissions instructions>", "# AGENTS.md instructions for", "<user_instructions>"].contains { text.hasPrefix($0) }
    }
}

enum ConversationHistoryMerge {
    struct Projection: Equatable { var historyCount: Int; var liveStart: Int }
    /// Preserve the persisted timeline and replace its matching tail with the
    /// current live bubble, so a streamed response can grow without duplication.
    static func project(history: [ConversationHistoryMessage], live: [(role: String, text: String)]) -> Projection {
        for liveIndex in live.indices.reversed() where !live[liveIndex].text.isEmpty {
            if let index = history.lastIndex(where: { message in
                guard message.role == live[liveIndex].role else { return false }
                let text = live[liveIndex].text
                return message.text == text || (message.role == "assistant" && min(message.text.count, text.count) >= 8
                    && (message.text.hasPrefix(text) || text.hasPrefix(message.text)))
            }) {
                if index == history.count - 1 {
                    if history[index].text.count > live[liveIndex].text.count {
                        return Projection(historyCount: history.count, liveStart: liveIndex + 1)
                    }
                    return Projection(historyCount: index, liveStart: liveIndex)
                }
                return Projection(historyCount: history.count, liveStart: liveIndex + 1)
            }
        }
        return Projection(historyCount: history.count, liveStart: 0)
    }
}
