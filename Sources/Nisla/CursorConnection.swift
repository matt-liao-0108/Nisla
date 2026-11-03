import Foundation
import SwiftUI

struct CursorSession: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    let cwd: String
}
struct CursorPermission: Identifiable {
    let id: String
    let wireID: Any
    let sessionID: String
    let method: String
    let params: [String: Any]
}

/// Cursor ACP v1 over stdio. Only sessions created through this client are owned.
@MainActor final class CursorConnection: ObservableObject {
    static let shared = CursorConnection()
    @AppStorage("cursorExecutable") var executable = "~/.local/bin/agent"
    @AppStorage("cursorWorkspace") var workspace = ""
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var status = "Cursor 未连接"
    @Published private(set) var error: String?
    @Published private(set) var sessions: [CursorSession] = []
    @Published private(set) var conversations: [String: [CodexChatEntry]] = [:]
    @Published private(set) var loadedSessions: Set<String> = []
    @Published private(set) var loadingSession = false
    @Published private(set) var activeSessionID: String?
    @Published private(set) var stopping = false
    @Published private(set) var permissions: [CursorPermission] = []
    @Published private(set) var activity = ""
    @Published private(set) var supportsLoad = false
    private var loadingID: String?
    private var replayBoundary = false
    private let preferences: UserDefaults
    private let executableOverride: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var generation = UUID()
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var cancelTimeout: Task<Void, Never>?
    private var runID: UUID?
    private var currentUser: UUID?
    private let writer = DispatchQueue(label: "nisla.cursor.acp.write")
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    init(executableOverride: String? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences; self.executableOverride = executableOverride
        _executable = AppStorage(wrappedValue: "~/.local/bin/agent", "cursorExecutable", store: preferences)
        _workspace = AppStorage(wrappedValue: "", "cursorWorkspace", store: preferences)
        if let data = preferences.data(forKey: "cursorSessions"), let saved = try? JSONDecoder().decode([CursorSession].self, from: data) {
            sessions = Array(saved.prefix(16))
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(sessions) { preferences.set(data, forKey: "cursorSessions") }
    }
    static func directory(_ path: String) -> String? {
        let path = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    func connect() {
        disconnect()
        let configured = CodexLaunch.path(executable)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [configured, home + "/.local/bin/agent", home + "/.local/bin/cursor-agent", "/opt/homebrew/bin/cursor-agent", "/usr/local/bin/cursor-agent"]
        guard let path = executableOverride ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "未找到 Cursor CLI。请先安装并运行 agent login，再连接。"; return
        }
        guard let cwd = Self.directory(workspace) else { error = "请先选择有效的 Cursor 项目文件夹"; return }
        if executableOverride == nil { executable = path }
        connecting = true; status = "正在连接 Cursor…"
        let token = generation
        let child = Process(); child.executableURL = URL(fileURLWithPath: path); child.arguments = ["acp"]
        child.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [URL(fileURLWithPath: path).deletingLastPathComponent().path, home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", environment["PATH"] ?? ""].joined(separator: ":")
        child.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        child.standardInput = inPipe; child.standardOutput = outPipe; child.standardError = errPipe
        input = inPipe.fileHandleForWriting; output = outPipe.fileHandleForReading; stderr = errPipe.fileHandleForReading; process = child
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Task { @MainActor [weak self] in guard let self, self.generation == token else { return }; self.consume(data) }
        }
        // Drain diagnostic output without persisting possible credentials or project content.
        stderr?.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.disconnect(); self.error = "Cursor CLI 已退出。请检查 CLI 是否支持 ACP，并先运行 agent login。"
            }
        }
        do { try child.run() } catch { disconnect(); self.error = "无法启动 Cursor CLI，请检查可执行文件路径"; return }
        request("initialize", params: ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false], "clientInfo": ["name": "nisla", "version": "1.0"]]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.connectionFailed(error)
            case .success(let value):
                guard value["protocolVersion"] as? Int == 1 else { self.connectionFailed(Failure(message: "Cursor ACP 协议版本不兼容")); return }
                self.supportsLoad = (value["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool == true
                let methods = value["authMethods"] as? [[String: Any]] ?? []
                if methods.contains(where: { $0["id"] as? String == "cursor_login" }) {
                    self.request("authenticate", params: ["methodId": "cursor_login"]) { [weak self] result in
                        guard let self else { return }
                        if case .failure(let error) = result { self.connectionFailed(error) } else { self.ready() }
                    }
                } else if methods.isEmpty { self.ready() }
                else { self.connectionFailed(Failure(message: "请先在终端运行 agent login，再连接 Cursor")) }
            }
        }
    }
    private func ready() { connected = true; connecting = false; status = "已连接 Cursor CLI" }
    private func connectionFailed(_ failure: Error) { disconnect(); error = failure.localizedDescription }
    func disconnect() {
        generation = UUID(); connected = false; connecting = false
        output?.readabilityHandler = nil; stderr?.readabilityHandler = nil
        let child = process; process = nil
        if child?.isRunning == true { child?.terminate() }
        try? input?.close(); try? output?.close(); try? stderr?.close()
        input = nil; output = nil; stderr = nil; buffer.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll(); pending.removeAll()
        cancelTimeout?.cancel(); cancelTimeout = nil
        for key in conversations.keys {
            for index in conversations[key]!.indices where [.waiting, .streaming, .sending].contains(conversations[key]![index].state) { conversations[key]![index].state = .interrupted }
        }
        loadedSessions = []; loadingSession = false; loadingID = nil; supportsLoad = false
        activeSessionID = nil; runID = nil; stopping = false; permissions = []; activity = ""
        status = "Cursor 未连接"; error = nil
    }
    func newSession(completion: @escaping (CursorSession) -> Void) {
        guard connected, !loadingSession, activeSessionID == nil else { return }
        guard let cwd = Self.directory(workspace) else { error = "请先选择有效的 Cursor 项目文件夹"; return }
        guard sessions.count < 16 else { error = "最多保留 16 个 Cursor 会话，请先移除不需要的记录"; return }
        loadingSession = true; error = nil
        request("session/new", params: ["cwd": cwd, "mcpServers": []]) { [weak self] result in
            guard let self else { return }; self.loadingSession = false
            switch result {
            case .failure(let error): self.error = error.localizedDescription
            case .success(let value):
                guard let id = value["sessionId"] as? String, !id.isEmpty else { self.error = "Cursor 返回了无效的会话"; return }
                let session = CursorSession(id: id, title: URL(fileURLWithPath: cwd).lastPathComponent, cwd: cwd)
                self.sessions.removeAll { $0.id == id }; self.sessions.insert(session, at: 0); self.loadedSessions.insert(id)
                self.save(); completion(session)
            }
        }
    }
    func load(_ session: CursorSession) {
        guard connected, supportsLoad, !loadedSessions.contains(session.id), !loadingSession, activeSessionID == nil,
              sessions.contains(where: { $0.id == session.id }) else { return }
        guard Self.directory(session.cwd) != nil else { error = "Cursor 项目文件夹已不存在，请重新选择文件夹并新建会话"; return }
        loadingSession = true; loadingID = session.id; replayBoundary = true; error = nil
        let oldHistory = conversations[session.id]
        conversations[session.id] = []
        request("session/load", params: ["sessionId": session.id, "cwd": session.cwd, "mcpServers": []]) { [weak self] result in
            guard let self else { return }; self.loadingSession = false; self.loadingID = nil
            switch result {
            case .failure(let error): self.conversations[session.id] = oldHistory; self.error = error.localizedDescription
            case .success: self.loadedSessions.insert(session.id)
            }
        }
    }
    func forget(_ session: CursorSession) {
        guard activeSessionID != session.id, !loadingSession else { return }
        sessions.removeAll { $0.id == session.id }; conversations.removeValue(forKey: session.id); loadedSessions.remove(session.id); save()
    }
    func canSend(to id: String) -> Bool { connected && loadedSessions.contains(id) && !loadingSession && activeSessionID == nil }
    func send(_ text: String, to id: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(to: id), !text.isEmpty, text.utf8.count <= 65_536 else { return }
        error = nil; activeSessionID = id; stopping = false; activity = "等待 Cursor 回复…"
        let token = UUID(); runID = token
        let user = CodexChatEntry(role: .user, text: text, state: .sending)
        let assistant = CodexChatEntry(role: .assistant, text: "", state: .waiting)
        currentUser = user.id
        if conversations[id, default: []].isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].title = String(text.prefix(48)); save()
        }
        append(user, to: id); append(assistant, to: id)
        // Prompt results arrive only when the whole turn ends, not when it is accepted.
        request("session/prompt", params: ["sessionId": id, "prompt": [["type": "text", "text": text]]], timeout: nil) { [weak self] result in
            guard let self, self.runID == token else { return }
            switch result {
            case .failure(let error):
                self.update(user.id, in: id, state: .failed); self.update(assistant.id, in: id, state: .failed); self.error = error.localizedDescription
            case .success(let value):
                self.update(user.id, in: id, state: .complete)
                self.update(assistant.id, in: id, state: value["stopReason"] as? String == "cancelled" ? .interrupted : .complete)
            }
            self.cancelPermissions(); self.activeSessionID = nil; self.runID = nil; self.stopping = false; self.activity = ""
            self.cancelTimeout?.cancel(); self.cancelTimeout = nil
        }
    }
    func stop() {
        guard let id = activeSessionID else { return }
        error = nil; stopping = true
        notify("session/cancel", params: ["sessionId": id]); cancelPermissions()
        cancelTimeout?.cancel()
        let token = runID
        cancelTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.runID == token, self.activeSessionID == id else { return }
            self.stopping = false; self.error = "尚未收到 Cursor 停止确认，可重试停止或断开连接"
        }
    }
    func respond(_ permission: CursorPermission, result: [String: Any]) {
        guard permissions.contains(where: { $0.id == permission.id }) else { return }
        permissions.removeAll { $0.id == permission.id }
        write(["jsonrpc": "2.0", "id": permission.wireID, "result": result])
    }
    func choose(_ permission: CursorPermission, optionID: String) {
        let options = permission.params["options"] as? [[String: Any]] ?? []
        guard options.contains(where: { $0["optionId"] as? String == optionID && ["allow_once", "reject_once"].contains($0["kind"] as? String ?? "") }) else { return }
        respond(permission, result: ["outcome": ["outcome": "selected", "optionId": optionID]])
    }
    private func cancelPermissions() {
        for permission in permissions {
            let result: [String: Any] = permission.method == "session/request_permission" ? ["outcome": ["outcome": "cancelled"]] : ["outcome": "cancelled"]
            respond(permission, result: result)
        }
    }
    private func append(_ entry: CodexChatEntry, to id: String) {
        conversations[id, default: []].append(entry); conversations[id] = Array(conversations[id]!.suffix(32))
    }
    private func update(_ entry: UUID, in id: String, state: CodexChatEntry.State) {
        if let i = conversations[id]?.firstIndex(where: { $0.id == entry }) { conversations[id]![i].state = state }
    }
    private func chunk(_ text: String, role: CodexChatEntry.Role, session: String) {
        guard !text.isEmpty else { return }
        let entries = conversations[session] ?? []
        let replay = loadingID == session
        if replay && (replayBoundary || entries.last?.role != role) {
            append(CodexChatEntry(role: role, text: "", state: .complete), to: session); replayBoundary = false
        }
        if !replay, role == .user { return } // Some agents echo the prompt already shown optimistically.
        guard let i = conversations[session]?.indices.last else { return }
        conversations[session]![i].text = String((conversations[session]![i].text + text).prefix(65_536))
        if !replay { conversations[session]![i].state = .streaming }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 8_388_608 else { connectionFailed(Failure(message: "Cursor 返回内容过大，连接已断开")); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { connectionFailed(Failure(message: "Cursor ACP 返回格式不兼容")); return }
            receive(row)
        }
    }
    private func receive(_ row: [String: Any]) {
        if row["method"] == nil, let id = row["id"] as? Int, let reply = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let failure = row["error"] as? [String: Any] {
                reply(.failure(Failure(message: String((failure["message"] as? String ?? L10n.text("Cursor 请求失败")).prefix(1024)))))
            } else if let value = row["result"] as? [String: Any] { reply(.success(value)) }
            else { reply(.failure(Failure(message: "Cursor ACP 返回格式不兼容"))) }
            return
        }
        guard let method = row["method"] as? String else { return }
        let params = row["params"] as? [String: Any] ?? [:]
        if method == "session/update", let id = params["sessionId"] as? String,
           loadedSessions.contains(id) || loadingID == id,
           let value = params["update"] as? [String: Any] {
            let kind = value["sessionUpdate"] as? String ?? ""
            if ["agent_message_chunk", "user_message_chunk"].contains(kind), let content = value["content"] as? [String: Any], content["type"] as? String == "text", let text = content["text"] as? String {
                chunk(text, role: kind == "user_message_chunk" ? .user : .assistant, session: id)
                if activeSessionID == id, let user = currentUser { update(user, in: id, state: .complete) }
            } else if kind == "tool_call" || kind == "tool_call_update" {
                if loadingID == id { replayBoundary = true }
                if activeSessionID == id { activity = String((value["title"] as? String ?? L10n.text("Cursor 正在执行工具")).prefix(300)) }
            }
            return
        }
        guard let wireID = row["id"] else { return }
        if ["session/request_permission", "cursor/ask_question", "cursor/create_plan"].contains(method),
           let active = activeSessionID, !stopping,
           (params["sessionId"] as? String ?? active) == active, permissions.count < 16 {
            if let user = currentUser { update(user, in: active, state: .complete) }
            permissions.append(CursorPermission(id: UUID().uuidString, wireID: wireID, sessionID: active, method: method, params: params))
        } else {
            write(["jsonrpc": "2.0", "id": wireID, "error": ["code": -32601, "message": "Unsupported client request"]])
        }
    }
    private func notify(_ method: String, params: [String: Any]) { write(["jsonrpc": "2.0", "method": method, "params": params]) }
    private func request(_ method: String, params: [String: Any], timeout: Double? = 30, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        sequence += 1; let id = sequence; pending[id] = completion
        if let timeout {
            timeouts[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self, let reply = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id); reply(.failure(Failure(message: "Cursor 请求超时，请重新连接")))
            }
        }
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }
    private func write(_ value: [String: Any]) {
        guard let input, var bytes = try? JSONSerialization.data(withJSONObject: value) else { return }
        bytes.append(10); let data = bytes; let token = generation
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.connectionFailed(Failure(message: "Cursor 连接写入失败，请重新连接"))
                }
            }
        }
    }
}
