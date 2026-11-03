import Foundation
import SwiftUI
import AppKit

enum CodexStartupFailure: Equatable {
    case unavailableSocket, unsupportedProxy, unsupportedServer, permission, configuration, unknown
    static func classify(_ data: Data) -> Self {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        if text.contains("socket") && ["no such file", "connection refused", "os error 2", "os error 61"].contains(where: text.contains) { return .unavailableSocket }
        if text.contains("proxy") && ["unrecognized subcommand", "unknown subcommand", "unexpected argument"].contains(where: text.contains) { return .unsupportedProxy }
        if text.contains("app-server") && ["unrecognized subcommand", "unknown subcommand"].contains(where: text.contains) { return .unsupportedServer }
        if ["failed to load config", "error loading config", "error parsing config", "toml parse error"].contains(where: text.contains) { return .configuration }
        if ["permission denied", "operation not permitted", "os error 13"].contains(where: text.contains) { return .permission }
        return .unknown
    }
    var message: String {
        switch self {
        case .unavailableSocket: "共享服务的控制 Socket 不存在或未监听。请启动提供共享服务的 Codex，或检查自定义 Socket 路径；也可手动切换独立服务。"
        case .unsupportedProxy: "此 Codex CLI 不支持共享服务代理。可更新 CLI，或手动切换独立服务。"
        case .unsupportedServer: "此可执行文件不支持 Codex app-server，请选择支持本地服务的 Codex CLI。"
        case .permission: "连接进程访问本地文件或 Socket 被拒绝。请检查文件权限；这不是辅助功能授权问题。"
        case .configuration: "Codex 本地配置无法加载。请检查所选 CLI 的配置格式与版本兼容性。"
        case .unknown: "连接进程未能完成启动。请核对 CLI 路径、版本和连接模式；未自动切换服务。"
        }
    }
}

/// Temporary bounded capture, never persisted or copied into exported logs.
final class CodexStartupCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > 65_536 { bytes = Data(bytes.suffix(65_536)) }
    }
    var failure: CodexStartupFailure {
        lock.lock(); defer { lock.unlock() }
        return CodexStartupFailure.classify(bytes)
    }
}

enum CodexLaunch {
    static func path(_ value: String) -> String {
        (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }
    static func arguments(mode: String, socket: String) -> [String] {
        // Stdio is the documented default. --stdio is not supported by all CLIs.
        if mode == "direct" { return ["app-server"] }
        let socket = path(socket)
        return ["app-server", "proxy"] + (socket.isEmpty ? [] : ["--sock", socket])
    }
}

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

struct CodexChatEntry: Identifiable, Equatable {
    enum Role { case user, assistant }
    enum State { case sending, waiting, streaming, complete, failed, interrupted }
    let id = UUID()
    let role: Role
    var text: String
    var state: State
}

struct CodexModel: Identifiable, Equatable {
    let id: String
    let name: String
    static func parse(_ row: [String: Any]) -> Self? {
        guard row["hidden"] as? Bool != true, let model = row["model"] as? String, !model.isEmpty else { return nil }
        return Self(id: model, name: row["displayName"] as? String ?? model)
    }
}

@MainActor final class CodexConnection: ObservableObject {
    static let shared = CodexConnection()
    @Published private(set) var models: [CodexModel] = []
    @Published private(set) var loadingModels = false
    @Published private(set) var modelError: String?
    @Published private(set) var selectedModels: [String: String] = [:]
    func selectModel(_ model: String, for thread: String) {
        guard connected, activeTurns[thread] == nil, !sendingThreads.contains(thread),
              model.isEmpty || models.contains(where: { $0.id == model }) else { return }
        selectedModels[thread] = model.isEmpty ? nil : model
    }
    func refreshModels() {
        guard connected, !loadingModels else { return }
        loadingModels = true; modelError = nil
        loadModels(cursor: nil, collected: [], seen: [])
    }
    private func loadModels(cursor: String?, collected: [CodexModel], seen: Set<String>) {
        var params: [String: Any] = ["limit": 100]
        if let cursor { params["cursor"] = cursor }
        request("model/list", parameters: params) { [weak self] result in
            guard let self, self.connected else { return }
            switch result {
            case .failure:
                self.loadingModels = false; self.modelError = "无法读取可用模型，请重试"
            case .success(let value):
                guard let rows = value["data"] as? [[String: Any]] else {
                    self.loadingModels = false; self.modelError = "无法读取可用模型，请重试"; return
                }
                var combined = collected
                for model in rows.compactMap(CodexModel.parse) where !combined.contains(where: { $0.id == model.id }) { combined.append(model) }
                if let next = value["nextCursor"] as? String, !next.isEmpty {
                    guard !seen.contains(next), seen.count < 100 else {
                        self.loadingModels = false; self.modelError = "无法读取可用模型，请重试"; return
                    }
                    self.loadModels(cursor: next, collected: combined, seen: seen.union([next]))
                } else { self.models = combined; self.loadingModels = false }
            }
        }
    }
    @Published var connected = false
    @Published var status = "未连接：本地日志监控仍可使用"
    @Published var diagnostics: [String] = []
    @Published var sessions: [CodexSession] = []
    @Published var quota = "额度尚未读取"
    @Published var requests: [AgentRequest] = []
    @Published var messages: [String: String] = [:]
    // Bounded, memory-only conversation history for messages seen by Nisla.
    @Published private(set) var conversations: [String: [CodexChatEntry]] = [:]
    private var conversationOrder: [String] = []
    @Published var activeTurns: [String: String] = [:]
    @Published private(set) var stoppingThreads: Set<String> = []
    @Published private(set) var stopErrors: [String: String] = [:]
    @Published private(set) var sendingThreads: Set<String> = []
    private var interruptingTurns: [String: String] = [:]
    private var stopConfirmationTasks: [String: Task<Void, Never>] = [:]
    private var completedTurnIDs: [String] = []
    @Published var threadErrors: [String: String] = [:]
    @Published var checkingThreads: Set<String> = []
    @Published var sending = false
    @Published var lastSendSucceeded = false
    @Published var lastSentThreadID: String?
    @Published var lastSentText: String?
    @Published private(set) var connecting = false
    @Published private(set) var canOfferDirectConnection = false
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
    private var generation = UUID()
    private let executableOverride: String?
    init(executableOverride: String? = nil, preferences: UserDefaults? = nil) {
        self.executableOverride = executableOverride
        if let preferences {
            _executable = AppStorage(wrappedValue: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "codexExecutable", store: preferences)
            _socket = AppStorage(wrappedValue: "", "codexSocket", store: preferences)
            _transport = AppStorage(wrappedValue: "proxy", "codexTransport", store: preferences)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func connect() {
        disconnect()
        canOfferDirectConnection = false
        if executableOverride == nil { self.executable = CodexLaunch.path(self.executable) }
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
        let mode = transport
        process.arguments = CodexLaunch.arguments(mode: mode, socket: socket)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let generation = self.generation
        let startup = CodexStartupCapture()
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
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            startup.append(data)
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { @MainActor in
                // Allow the final stderr callback to arrive before classification.
                try? await Task.sleep(for: .milliseconds(50))
                guard self?.process === process else { return }
                let reason = startup.failure
                self?.disconnect()
                self?.canOfferDirectConnection = mode != "direct" && [.unavailableSocket, .unsupportedProxy].contains(reason)
                self?.record("连接进程退出（\(code)）")
                self?.fail(reason.message)
            }
        }
        self.process = process
        do { try process.run() }
        catch { disconnect(); fail("无法启动连接进程：\(error.localizedDescription)"); return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        request("initialize", parameters: ["clientInfo": ["name": "nisla", "title": "Nisla", "version": version]]) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .success:
                guard self.write(["method": "initialized", "params": [:]]) else {
                    self.disconnect(); self.fail("初始化确认发送失败，请重新连接"); return
                }
                self.connected = true; self.connecting = false
                self.status = mode == "direct" ? "已连接独立 Codex 服务（非桌面共享连接）" : "已连接 Codex 本地服务"
                self.record("initialize 握手成功")
                self.refresh()
                self.refreshModels()
            case .failure(let error):
                if error.localizedDescription == "连接写入失败，请重新连接" {
                    // A process may exit before the first write. Let its stderr
                    // classification win, rather than hiding the startup cause.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(100))
                        guard let self, self.process === process, self.generation == generation else { return }
                        let reason = startup.failure
                        self.disconnect()
                        self.canOfferDirectConnection = mode != "direct" && [.unavailableSocket, .unsupportedProxy].contains(reason)
                        self.fail(reason.message)
                    }
                } else { self.disconnect(); self.fail(error.localizedDescription) }
            }
        }
    }

    /// Only called by an explicit recovery button, never on connection failure.
    func connectIndependently() {
        guard canOfferDirectConnection, !connecting else { return }
        transport = "direct"
        connect()
    }

    func disconnect() {
        generation = UUID()
        connected = false; connecting = false; sending = false
        models = []; selectedModels = [:]; loadingModels = false; modelError = nil
        for thread in Array(conversations.keys) {
            for index in conversations[thread]!.indices {
                if [.sending, .waiting, .streaming].contains(conversations[thread]![index].state) {
                    conversations[thread]![index].state = .interrupted
                }
            }
        }
        canOfferDirectConnection = false
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
        stopConfirmationTasks.values.forEach { $0.cancel() }; stopConfirmationTasks.removeAll()
        stoppingThreads.removeAll(); interruptingTurns.removeAll(); stopErrors.removeAll(); sendingThreads.removeAll()
        completedTurnIDs.removeAll()
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
                    let provenance = SessionProvenance.classify(row)
                    return CodexSession(id: id, title: row["name"] as? String ?? row["preview"] as? String ?? "Codex 会话", project: row["cwd"] as? String ?? "", modifiedAt: Date(timeIntervalSince1970: row["updatedAt"] as? Double ?? 0), isRunning: false, sourcePath: row["path"] as? String, internalKind: provenance.kind, parentThreadID: provenance.parent)
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
        guard connected, !checkingThreads.contains(id), activeTurns[id] == nil, !sendingThreads.contains(id) else { return }
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
        guard connected, !sending, !stoppingThreads.contains(threadID), threadErrors[threadID] == nil, !checkingThreads.contains(threadID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let chosenModel = selectedModels[threadID]
        if activeTurns[threadID] == nil, let chosenModel, !models.contains(where: { $0.id == chosenModel }) {
            modelError = "所选模型已不可用，请刷新并重新选择"; return
        }
        sending = true; lastSendSucceeded = false
        sendingThreads.insert(threadID)
        stopErrors.removeValue(forKey: threadID)
        if conversations[threadID, default: []].isEmpty, let previous = messages[threadID], !previous.isEmpty {
            appendChat(CodexChatEntry(role: .assistant, text: previous, state: .complete), to: threadID)
        }
        finishAssistant(in: threadID, state: .complete)
        let user = CodexChatEntry(role: .user, text: String(text.prefix(65_536)), state: .sending)
        let assistant = CodexChatEntry(role: .assistant, text: "", state: .waiting)
        appendChat(user, to: threadID)
        appendChat(assistant, to: threadID)
        let input: [[String: Any]] = [["type": "text", "text": text]]
        let finish: (Result<[String: Any], Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.sending = false; self.sendingThreads.remove(threadID)
            switch result {
            case .success(let value):
                // Capture the response too: turn/started may arrive later.
                if let turn = value["turn"] as? [String: Any], let id = turn["id"] as? String,
                   !self.completedTurnIDs.contains(id) {
                    self.activeTurns[threadID] = id
                }
                self.updateChat(user.id, in: threadID, state: .complete)
                self.lastSentThreadID = threadID; self.lastSentText = text
                self.lastSendSucceeded = true; self.status = "消息已发送"; self.record("消息发送成功")
                if self.stoppingThreads.contains(threadID) { self.interruptActiveTurn(threadID) }
            case .failure(let error):
                self.updateChat(user.id, in: threadID, state: .failed)
                self.updateChat(assistant.id, in: threadID, state: .failed)
                self.handleThreadError(error, id: threadID)
                if self.activeTurns[threadID] == nil { self.stoppingThreads.remove(threadID) }
                else if self.stoppingThreads.contains(threadID) { self.interruptActiveTurn(threadID) }
            }
        }
        if let turn = activeTurns[threadID] {
            request("turn/steer", parameters: ["threadId": threadID, "expectedTurnId": turn, "input": input], completion: finish)
        } else {
            request("thread/resume", parameters: ["threadId": threadID, "excludeTurns": true]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success:
                    var params: [String: Any] = ["threadId": threadID, "input": input]
                    if let chosenModel { params["model"] = chosenModel }
                    self.request("turn/start", parameters: params, completion: finish)
                }
            }
        }
    }

    func canStop(_ threadID: String) -> Bool {
        connected && (activeTurns[threadID] != nil || sendingThreads.contains(threadID))
    }

    /// A click may precede turn/start's response. Keep the intent until its ID arrives.
    func stop(_ threadID: String) {
        guard canStop(threadID), !stoppingThreads.contains(threadID) else { return }
        stopErrors.removeValue(forKey: threadID)
        stoppingThreads.insert(threadID)
        interruptActiveTurn(threadID)
    }

    private func interruptActiveTurn(_ threadID: String) {
        guard let turnID = activeTurns[threadID], interruptingTurns[threadID] == nil else { return }
        interruptingTurns[threadID] = turnID
        request("turn/interrupt", parameters: ["threadId": threadID, "turnId": turnID]) { [weak self] result in
            guard let self, self.activeTurns[threadID] == turnID,
                  self.interruptingTurns[threadID] == turnID else { return }
            switch result {
            case .failure:
                self.interruptingTurns.removeValue(forKey: threadID)
                self.stoppingThreads.remove(threadID)
                self.stopErrors[threadID] = "停止请求失败，任务可能仍在运行。请重试或在 Codex 中停止。"
            case .success:
                // The RPC acknowledges cancellation, not completed cleanup.
                self.stopConfirmationTasks[threadID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self, self.activeTurns[threadID] == turnID else { return }
                    self.interruptingTurns.removeValue(forKey: threadID)
                    self.stoppingThreads.remove(threadID)
                    self.stopConfirmationTasks.removeValue(forKey: threadID)
                    self.stopErrors[threadID] = "尚未收到停止确认，任务可能仍在运行。可重试停止。"
                }
            }
        }
    }

    private func appendChat(_ entry: CodexChatEntry, to thread: String) {
        conversationOrder.removeAll { $0 == thread }; conversationOrder.append(thread)
        while conversationOrder.count > 16 { conversations.removeValue(forKey: conversationOrder.removeFirst()) }
        conversations[thread, default: []].append(entry)
        conversations[thread] = Array(conversations[thread]!.suffix(32))
    }

    private func updateChat(_ id: UUID, in thread: String, state: CodexChatEntry.State) {
        guard let index = conversations[thread]?.firstIndex(where: { $0.id == id }) else { return }
        conversations[thread]![index].state = state
    }

    private func finishAssistant(in thread: String, state: CodexChatEntry.State) {
        guard let index = conversations[thread]?.lastIndex(where: {
            $0.role == .assistant && [.waiting, .streaming].contains($0.state)
        }) else { return }
        conversations[thread]![index].state = state
    }

    private func appendAssistantDelta(_ delta: String, in thread: String) {
        guard !delta.isEmpty else { return }
        if conversations[thread]?.last?.role != .assistant || ![.waiting, .streaming].contains(conversations[thread]!.last!.state) {
            appendChat(CodexChatEntry(role: .assistant, text: "", state: .streaming), to: thread)
        }
        let index = conversations[thread]!.count - 1
        conversations[thread]![index].text = String((conversations[thread]![index].text + delta).suffix(65_536))
        conversations[thread]![index].state = .streaming
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
                    if let id = params["turnId"] as? String,
                       completedTurnIDs.contains(id) || (activeTurns[thread] != nil && activeTurns[thread] != id) { continue }
                    let delta = params["delta"] as? String ?? ""
                    let text = messages[thread, default: ""] + delta
                    messages[thread] = String(text.suffix(65_536))
                    appendAssistantDelta(delta, in: thread)
                case "turn/started":
                    guard let id = (params["turn"] as? [String: Any])?["id"] as? String,
                          !completedTurnIDs.contains(id) else { continue }
                    activeTurns[thread] = id
                    messages[thread] = ""
                    if conversations[thread]?.last?.role != .assistant || ![.waiting, .streaming].contains(conversations[thread]!.last!.state) {
                        appendChat(CodexChatEntry(role: .assistant, text: "", state: .waiting), to: thread)
                    }
                    if stoppingThreads.contains(thread) { interruptActiveTurn(thread) }
                case "turn/completed":
                    let turn = params["turn"] as? [String: Any]
                    if let id = turn?["id"] as? String {
                        guard !completedTurnIDs.contains(id) else { continue }
                        completedTurnIDs.append(id); completedTurnIDs = Array(completedTurnIDs.suffix(128))
                        if let active = activeTurns[thread], active != id { continue }
                    }
                    activeTurns.removeValue(forKey: thread)
                    stoppingThreads.remove(thread); interruptingTurns.removeValue(forKey: thread)
                    stopErrors.removeValue(forKey: thread)
                    stopConfirmationTasks.removeValue(forKey: thread)?.cancel()
                    requests.removeAll { $0.threadID == thread }
                    let state: CodexChatEntry.State = turn?["status"] as? String == "failed" ? .failed
                        : turn?["status"] as? String == "interrupted" ? .interrupted : .complete
                    finishAssistant(in: thread, state: state)
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
