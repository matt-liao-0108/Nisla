import Foundation
import SwiftUI
import AppKit

enum CodexExecutableLocator {
    static func resolve(configured: String, candidates: [String], executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ([configured] + candidates).first(where: executable)
    }

    static var installedCandidates: [String] {
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let apps = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")].compactMap { $0 }
            + folders.flatMap { folder in ["Codex.app", "ChatGPT.app"].map { folder.appendingPathComponent($0) } }
        return apps.flatMap { app in
            ["Contents/Resources/codex", "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
                .map { app.appendingPathComponent($0).path }
        } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    }
}

struct AgentRequest: Identifiable {
    let id: String
    let wireID: Any
    let method: String
    let threadID: String
    let parameters: [String: Any]
    var description: String {
        (parameters["reason"] as? String) ?? (parameters["command"] as? String) ?? "Codex 请求你的确认"
    }
}

@MainActor final class CodexConnection: ObservableObject {
    static let shared = CodexConnection()
    @Published var connected = false
    @Published var status = "未连接：本地日志监控仍可使用"
    @Published var diagnostics: [String] = []
    @Published var sessions: [CodexSession] = []
    @Published var quota = "额度尚未读取"
    @Published var requests: [AgentRequest] = []
    @Published var messages: [String: String] = [:]
    @Published var activeTurns: [String: String] = [:]
    @Published var threadErrors: [String: String] = [:]
    @Published var checkingThreads: Set<String> = []
    @Published var sending = false
    @Published var lastSendSucceeded = false
    @Published var lastSentThreadID: String?
    @Published var lastSentText: String?
    @AppStorage("codexExecutable") var executable = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    @AppStorage("codexSocket") var socket = ""
    @AppStorage("codexTransport") var transport = "proxy"
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var replies: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var connecting = false
    private var generation = UUID()
    private let executableOverride: String?
    init(executableOverride: String? = nil) { self.executableOverride = executableOverride }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func connect() {
        disconnect()
        if executableOverride == nil, !FileManager.default.isExecutableFile(atPath: self.executable),
           let resolved = CodexExecutableLocator.resolve(configured: self.executable, candidates: CodexExecutableLocator.installedCandidates) {
            self.executable = resolved
        }
        let executable = executableOverride ?? self.executable
        guard FileManager.default.isExecutableFile(atPath: executable) else { fail("找不到 Codex CLI，请在设置中选择可执行文件。"); return }
        connecting = true
        status = "正在连接 Codex 本地服务…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = transport == "direct" ? ["app-server", "--stdio"] : ["app-server", "proxy"] + (socket.isEmpty ? [] : ["--sock", socket])
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let generation = self.generation
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard self?.generation == generation else { return }
                self?.receive(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard self?.generation == generation else { return }
                // Do not retain environment paths, tokens, or server stderr in diagnostics.
                self?.record("Codex 服务返回了诊断输出（\(data.count) 字节）；请检查服务是否运行及 Socket 配置。")
            }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { @MainActor in
                guard self?.process === process else { return }
                self?.disconnect()
                self?.fail("连接进程退出（\(code)）。请启动支持本地服务的 Codex，或配置其控制 Socket。")
            }
        }
        self.process = process
        do { try process.run() }
        catch { disconnect(); fail("无法启动连接进程：\(error.localizedDescription)"); return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        request("initialize", parameters: ["clientInfo": ["name": "nisla", "title": "Nisla", "version": version]]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard self.write(["method": "initialized", "params": [:]]) else {
                    self.disconnect(); self.fail("初始化确认发送失败，请重新连接"); return
                }
                self.connected = true; self.connecting = false; self.status = "已连接 Codex 本地服务"
                self.record("initialize 握手成功")
                self.refresh()
            case .failure(let error): self.disconnect(); self.fail(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        generation = UUID()
        connected = false; connecting = false; sending = false
        lastSendSucceeded = false; lastSentThreadID = nil; lastSentText = nil
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        let running = process; process = nil
        if running?.isRunning == true { running?.terminate() }
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; buffer.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }; timeoutTasks.removeAll()
        let pending = Array(replies.values); replies.removeAll()
        pending.forEach { $0(.failure(Failure(message: "连接已断开"))) }
        requests.removeAll(); activeTurns.removeAll()
        messages.removeAll(); sessions.removeAll()
        threadErrors.removeAll(); checkingThreads.removeAll()
        quota = "额度尚未读取"
        status = "未连接：本地日志监控仍可使用"
    }

    func refresh() {
        guard connected else { return }
        request("thread/list", parameters: ["limit": 100]) { [weak self] result in
            if case .success(let value) = result, let rows = value["data"] as? [[String: Any]] {
                self?.sessions = rows.compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    return CodexSession(id: id, title: row["name"] as? String ?? row["preview"] as? String ?? "Codex 会话", project: row["cwd"] as? String ?? "", modifiedAt: Date(timeIntervalSince1970: row["updatedAt"] as? Double ?? 0), isRunning: false, sourcePath: row["path"] as? String)
                }
            } else if case .failure(let error) = result { self?.fail(error.localizedDescription) }
        }
        request("account/rateLimits/read", parameters: [:]) { [weak self] result in
            switch result {
            case .success(let value): self?.updateQuota(value)
            case .failure(let error): self?.quota = "额度不可用：\(error.localizedDescription)"
            }
        }
    }

    func follow(_ id: String) {
        guard connected, !checkingThreads.contains(id) else { return }
        checkingThreads.insert(id)
        request("thread/resume", parameters: ["threadId": id, "excludeTurns": true]) { [weak self] result in
            guard let self else { return }
            self.checkingThreads.remove(id)
            switch result {
            case .success: self.threadErrors.removeValue(forKey: id)
            case .failure(let error): self.handleThreadError(error, id: id)
            }
        }
    }

    private func handleThreadError(_ error: Error, id: String) {
        let raw = error.localizedDescription
        let message = raw.lowercased().contains("already has an active writer")
            ? "此会话正由 Codex 或其他进程占用，Nisla 暂时只能查看。请在 Codex 中继续；占用释放后可重新检查。"
            : "会话操作失败：\(raw)"
        threadErrors[id] = message
        record(raw)
        status = message
    }

    func send(_ text: String, to threadID: String) {
        guard connected, !sending, threadErrors[threadID] == nil, !checkingThreads.contains(threadID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true; lastSendSucceeded = false
        let input: [[String: Any]] = [["type": "text", "text": text]]
        let finish: (Result<[String: Any], Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.sending = false
            switch result {
            case .success:
                self.lastSentThreadID = threadID; self.lastSentText = text
                self.lastSendSucceeded = true; self.status = "消息已发送"; self.record("消息发送成功")
            case .failure(let error): self.handleThreadError(error, id: threadID)
            }
        }
        if let turn = activeTurns[threadID] {
            request("turn/steer", parameters: ["threadId": threadID, "expectedTurnId": turn, "input": input], completion: finish)
        } else {
            request("thread/resume", parameters: ["threadId": threadID, "excludeTurns": true]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success: self.request("turn/start", parameters: ["threadId": threadID, "input": input], completion: finish)
                }
            }
        }
    }

    func respond(_ request: AgentRequest, result: [String: Any]) {
        guard requests.contains(where: { $0.id == request.id }) else { return }
        guard write(["id": request.wireID, "result": result]) else { return }
        requests.removeAll { $0.id == request.id }
        record("已响应 \(request.method)")
    }

    private func request(_ method: String, parameters: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        sequence += 1
        let id = sequence
        replies[id] = completion
        guard write(["id": id, "method": method, "params": parameters]) else {
            replies.removeValue(forKey: id)?(.failure(Failure(message: "连接写入失败，请重新连接")))
            return
        }
        timeoutTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let callback = self.replies.removeValue(forKey: id) else { return }
            self.timeoutTasks.removeValue(forKey: id)
            callback(.failure(Failure(message: "\(method) 请求超时")))
        }
    }

    @discardableResult private func write(_ object: [String: Any]) -> Bool {
        guard let input, var bytes = try? JSONSerialization.data(withJSONObject: object) else { return false }
        bytes.append(10)
        do { try input.write(contentsOf: bytes); return true }
        catch { fail("连接写入失败"); return false }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 8_388_608 else { disconnect(); fail("协议消息超过限制"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = row["id"] as? Int, row["method"] == nil, let callback = replies.removeValue(forKey: id) {
                timeoutTasks.removeValue(forKey: id)?.cancel()
                if let error = row["error"] as? [String: Any] { callback(.failure(Failure(message: error["message"] as? String ?? "协议错误"))) }
                else { callback(.success(row["result"] as? [String: Any] ?? [:])) }
                continue
            }
            guard let method = row["method"] as? String else { continue }
            let params = row["params"] as? [String: Any] ?? [:]
            let thread = params["threadId"] as? String ?? ""
            if let id = row["id"] {
                if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput"].contains(method) {
                    requests.append(AgentRequest(id: String(describing: id), wireID: id, method: method, threadID: thread, parameters: params))
                    NotificationCenter.default.post(name: .init("IslandAgentAlert"), object: nil)
                } else { write(["id": id, "error": ["code": -32601, "message": "Nisla does not support this request"]]) }
            } else {
                switch method {
                case "item/agentMessage/delta":
                    let text = messages[thread, default: ""] + (params["delta"] as? String ?? "")
                    messages[thread] = String(text.suffix(65_536))
                case "turn/started":
                    activeTurns[thread] = (params["turn"] as? [String: Any])?["id"] as? String
                    messages[thread] = ""
                case "turn/completed": activeTurns.removeValue(forKey: thread)
                case "account/rateLimits/updated": updateQuota(params)
                case "serverRequest/resolved":
                    let id = String(describing: params["requestId"] ?? "")
                    requests.removeAll { $0.id == id }
                default: break
                }
            }
        }
    }

    private func updateQuota(_ value: [String: Any]) {
        let buckets = value["rateLimitsByLimitId"] as? [String: [String: Any]]
        let values = buckets.map { Array($0.values) } ?? (value["rateLimits"] as? [String: Any]).map { [$0] } ?? []
        let lines = values.flatMap { bucket in
            ["primary", "secondary"].compactMap { key -> String? in
                guard let window = bucket[key] as? [String: Any], let used = window["usedPercent"] as? Double, used.isFinite else { return nil }
                let duration = window["windowDurationMins"] as? Int ?? 0
                let reset = (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "未知"
                return "\(bucket["limitName"] as? String ?? "Codex") \(duration) 分钟额度：剩余 \(Int(min(100, max(0, 100 - used))))%，\(reset) 重置"
            }
        }
        quota = lines.isEmpty ? "当前账户未提供可用额度数据" : lines.joined(separator: "\n")
    }

    private func record(_ line: String) { diagnostics.append(Date.now.formatted(date: .omitted, time: .standard) + " " + String(line.prefix(1000))); diagnostics = Array(diagnostics.suffix(50)) }
    private func fail(_ message: String) { status = message; record(message) }
}
