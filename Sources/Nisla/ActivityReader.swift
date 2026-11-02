import Foundation

enum ActivityReader {
    // Read only a bounded tail, ignoring incomplete records while Codex appends.
    static func read(path: String, now: Date = .now, previous: SessionActivity? = nil) -> SessionActivity {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return SessionActivity(message: "无法读取会话文件，请刷新会话列表或重新置顶") }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return SessionActivity() }
        let offset = length > 1_048_576 ? length - 1_048_576 : 0
        try? file.seek(toOffset: offset)
        guard let data = try? file.readToEnd() else { return SessionActivity() }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        let tail = parse(data: data, modified: modified, now: now, previous: previous)
        guard tail.phase == .unknown, offset > 0, previous == nil else { return tail }
        // Large tool outputs can push task_started outside the tail. Stream the
        // file once with bounded memory to recover the last explicit lifecycle.
        try? file.seek(toOffset: 0)
        var pending = Data()
        var recovered = SessionActivity(updatedAt: modified)
        while let chunk = try? file.read(upToCount: 1_048_576), !chunk.isEmpty {
            pending.append(chunk)
            if let newline = pending.lastIndex(of: 10) {
                recovered = parse(data: Data(pending[...newline]), modified: modified, now: now, previous: recovered)
                pending.removeSubrange(...newline)
            }
            if pending.count > 16_777_216 { pending.removeAll() }
        }
        return recovered
    }

    static func parse(data: Data, modified: Date, now: Date = .now, previous: SessionActivity? = nil) -> SessionActivity {
        var result = previous ?? SessionActivity(updatedAt: modified)
        result.updatedAt = modified
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var waitingCallID = result.pendingCallID
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let bytes = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String ?? ""
            if row["type"] as? String == "event_msg" {
                switch type {
                case "task_started":
                    waitingCallID = nil
                    result.phase = .running
                    if result.message == SessionActivity().message { result.message = "Codex 正在处理任务" }
                    result.startedAt = (row["timestamp"] as? String).flatMap { formatter.date(from: $0) }
                case "task_complete":
                    waitingCallID = nil
                    result.phase = .completed
                    if let message = payload["last_agent_message"] as? String, !message.isEmpty { result.message = String(message.prefix(4000)) }
                case "turn_aborted": waitingCallID = nil; result.phase = .interrupted; result.message = "本轮任务已中断"
                default: break
                }
            }
            if row["type"] as? String == "response_item" {
                if type == "message", payload["role"] as? String == "assistant",
                   let blocks = payload["content"] as? [[String: Any]] {
                    let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { result.message = String(text.prefix(4000)) }
                }
                if ["function_call", "custom_tool_call"].contains(type),
                   let name = payload["name"] as? String,
                   name.contains("request_user_input") {
                    result.phase = .waiting
                    waitingCallID = payload["call_id"] as? String
                    result.message = "Codex 提出了问题，请打开会话回答"
                }
                if ["function_call_output", "custom_tool_call_output"].contains(type), result.phase == .waiting,
                   let waitingCallID, payload["call_id"] as? String == waitingCallID {
                    result.phase = .running
                    result.pendingCallID = nil
                }
            }
        }
        result.pendingCallID = result.phase == .waiting ? waitingCallID : nil
        if [.running, .waiting].contains(result.phase), now.timeIntervalSince(modified) > 600 {
            result.phase = .unknown
            result.message = "超过 10 分钟未收到本地事件，请打开 Codex 确认"
        }
        return result
    }
}
