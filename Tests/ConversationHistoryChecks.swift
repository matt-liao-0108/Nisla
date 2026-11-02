import Foundation

@main struct ConversationHistoryChecks {
    static func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload], options: [.sortedKeys])
        data.append(10); return data
    }
    static func message(_ role: String, _ text: String) throws -> Data {
        try record("response_item", ["type": "message", "role": role, "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]])
    }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NislaHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.jsonl")
        var data = try message("system", "Never display system instructions")
        data.append(try message("user", "<environment_context>metadata</environment_context>"))
        for index in 0..<40 {
            data.append(try record("event_msg", ["type": "user_message", "message": "Question \(index)"]))
            data.append(try message("user", "Question \(index)"))
            data.append(try record("response_item", ["type": "reasoning", "summary": "Never display reasoning"]))
            data.append(try message("assistant", "Reply \(index)"))
        }
        data.append(try record("event_msg", ["type": "task_started"]))
        data.append(Data(#"{"type":"response_item","payload":{"type":"message""#.utf8))
        try data.write(to: file)
        let latest = ConversationHistoryReader.page(path: file.path)
        precondition(!latest.unavailable && latest.messages.count == 24 && latest.before > 0)
        precondition(latest.messages.last?.text == "Reply 39")
        var all = latest.messages, cursor = latest.before
        while cursor > 0 {
            let page = ConversationHistoryReader.page(path: file.path, before: cursor, format: latest.format)
            precondition(page.before < cursor)
            all = page.messages + all; cursor = page.before
        }
        precondition(all.count == 80 && Set(all.map(\.id)).count == 80)
        precondition(all.first?.text == "Question 0")
        precondition(all.enumerated().allSatisfy { $0.element.role == ($0.offset.isMultiple(of: 2) ? "user" : "assistant") })
        let unchanged = try Data(contentsOf: file)
        precondition(unchanged == data)
        print("PASS: paginated read-only history survives task_started, ignores partial records, duplicate events, context, tools and reasoning")
        let revision = ConversationHistoryReader.revision(path: file.path)!
        data = data.prefix(data.lastIndex(of: 10)! + 1)
        data.append(try message("user", "A new turn")); try data.write(to: file)
        precondition(ConversationHistoryReader.revision(path: file.path) != revision)
        precondition(ConversationHistoryReader.page(path: file.path).messages.last?.text == "A new turn")
        let small = ConversationHistoryReader.page(path: file.path, byteBudget: 1024)
        precondition(small.messages.last?.text == "A new turn" && small.before > 0)
        precondition(ConversationHistoryReader.page(path: folder.appendingPathComponent("missing").path).unavailable)
        let legacy = folder.appendingPathComponent("events.jsonl")
        var events = try record("event_msg", ["type": "user_message", "message": "Legacy user"])
        events.append(try record("event_msg", ["type": "agent_message", "message": "Legacy reply"]))
        try events.write(to: legacy)
        precondition(ConversationHistoryReader.page(path: legacy.path).messages.map(\.text) == ["Legacy user", "Legacy reply"])
        print("PASS: append revisions, bounded windows, missing files and legacy event format")
        let history = [ConversationHistoryMessage(offset: 1, role: "user", text: "Question"), .init(offset: 2, role: "assistant", text: "Previous answer")]
        let live = [(role: "user", text: "Question"), (role: "assistant", text: "Previous answer"), (role: "user", text: "Next question"), (role: "assistant", text: "")]
        precondition(ConversationHistoryMerge.project(history: history, live: live) == .init(historyCount: 1, liveStart: 1))
        precondition(ConversationHistoryMerge.project(history: history, live: [("assistant", "Previous answer expanded")]) == .init(historyCount: 1, liveStart: 0))
        precondition(ConversationHistoryMerge.project(history: history, live: [("assistant", "Previous")]) == .init(historyCount: 2, liveStart: 1))
        let started = try record("event_msg", ["type": "task_started"])
        let activity = ActivityReader.parse(data: started, modified: .now, previous: SessionActivity(phase: .completed, message: "Previous answer"))
        precondition(activity.phase == .running && activity.message == "Previous answer")
        print("PASS: streamed/persisted overlap is deduplicated; new tasks do not erase previous summaries")
    }
}
