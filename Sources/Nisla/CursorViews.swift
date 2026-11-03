import SwiftUI
import AppKit

struct AgentProviderPicker: View {
    @EnvironmentObject private var store: PinStore
    var body: some View {
        Picker(L10n.text("Agent 来源"), selection: $store.agentProvider) {
            Text("Codex").tag("codex")
            Text("Cursor").tag("cursor")
        }.pickerStyle(.menu).labelsHidden().fixedSize()
            .accessibilityLabel(L10n.text("Agent 来源"))
    }
}

struct AgentSettings: View {
    @EnvironmentObject private var store: PinStore
    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.text("Agent 来源"), selection: $store.agentProvider) {
                Text("Codex").tag("codex"); Text("Cursor").tag("cursor")
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 10)
            if store.agentProvider == "cursor" { CursorSettings() } else { CodexSettings() }
        }
    }
}

struct CursorSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var connection = CursorConnection.shared
    var body: some View {
        Form {
            Section(L10n.text("Cursor 连接")) {
                Text(L10n.text(connection.status)).font(.caption)
                TextField(L10n.text("Cursor CLI 可执行文件路径"), text: $connection.executable).disabled(connection.connecting || connection.connected)
                TextField(L10n.text("Cursor 项目文件夹"), text: $connection.workspace).disabled(connection.connecting || connection.connected)
                Button(L10n.text("选择项目文件夹…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { connection.workspace = url.path }
                }.disabled(connection.connecting || connection.connected)
                HStack {
                    Button(L10n.text(connection.connecting ? "正在连接…" : "连接 / 重连")) { connection.connect() }.disabled(connection.connecting || connection.activeSessionID != nil)
                    Button(L10n.text("断开")) { connection.disconnect() }.disabled(!connection.connected && !connection.connecting)
                }
                if let error = connection.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Section(L10n.text("Cursor 使用说明")) {
                Text(L10n.text("先安装支持 ACP 的 Cursor CLI，在终端运行 agent login，再选择项目文件夹并连接。仅安装 Cursor 编辑器不足以连接。"))
                    .font(.caption).foregroundStyle(.secondary)
                Link(L10n.text("Cursor CLI 安装说明"), destination: URL(string: "https://cursor.com/docs/cli/installation")!)
                Text(L10n.text("在 Agent 页切换到 Cursor 并新建会话。支持流式回复、停止和逐次权限确认；不会接管 Cursor 编辑器里的聊天。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("Nisla 只保存最近 16 个 Cursor 会话的标识、标题和项目路径；消息缓存仅在内存保留最近 32 条。恢复历史取决于 CLI 的 session/load 支持。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct CursorShelf: View {
    @EnvironmentObject private var store: PinStore
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var connection = CursorConnection.shared
    @State private var selected: CursorSession?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentProviderPicker()
                Spacer()
                Button(L10n.text("新建会话")) { connection.newSession { selected = $0 } }
                    .disabled(!connection.connected || connection.loadingSession || connection.activeSessionID != nil)
            }
            if let error = connection.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            if !connection.connected {
                Text(L10n.text(connection.status)).font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("在设置 → Agent → Cursor 中配置 CLI 和项目文件夹，然后连接。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text(connection.connecting ? "正在连接…" : "连接 Cursor")) { connection.connect() }.disabled(connection.connecting)
            }
            if connection.sessions.isEmpty {
                Text(L10n.text("新建 Cursor 会话后，可在这里查看并回复。"))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: ShelfGeometry.codexRowSpacing) {
                        ForEach(connection.sessions) { session in
                            HStack(spacing: 10) {
                                CursorApplicationIcon().frame(width: 28, height: 28)
                                Button { selected = session } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(connection.activeSessionID == session.id ? L10n.text(connection.permissions.isEmpty ? "正在处理" : "等待确认") : session.cwd)
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { connection.forget(session) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).help(L10n.text("移除本地会话记录"))
                                    .disabled(connection.activeSessionID == session.id || connection.loadingSession)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 10).frame(height: ShelfGeometry.codexRowHeight)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.foregroundStyle(.white)
        .popover(item: $selected) { session in
            CursorConversation(session: session).environmentObject(store)
                .background(ShelfInteractionBoundary(preview: true))
        }
        .onChange(of: store.previewDismissal) { _, _ in selected = nil }
        .onChange(of: selected) { _, session in store.previewOpen = session != nil }
        .onDisappear { store.previewOpen = false }
    }
}

struct CursorConversation: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var connection = CursorConnection.shared
    let session: CursorSession
    @State private var draft = ""
    @State private var followLatest = true
    private var entries: [CodexChatEntry] { connection.conversations[session.id] ?? [] }
    private var running: Bool { connection.activeSessionID == session.id }
    private var canSend: Bool { connection.canSend(to: session.id) && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 65_536 }
    private func send() {
        guard canSend else { return }
        connection.send(draft, to: session.id); draft = ""; followLatest = true
    }
    private func restoreFailedDraft() {
        if draft.isEmpty, entries.last?.state == .failed,
           let user = entries.last(where: { $0.role == .user }) { draft = user.text }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(session.title).font(.headline).lineLimit(2)
                Spacer()
                if running {
                    Button(L10n.text(connection.stopping ? "正在停止…" : "停止")) { connection.stop() }.disabled(connection.stopping)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in CodexChatRow(entry: entry, project: session.cwd, agentName: "Cursor") }
                        if running { Text(L10n.text(connection.activity)).font(.caption).foregroundStyle(.secondary) }
                        ForEach(connection.permissions.filter { $0.sessionID == session.id }) { request in CursorPermissionView(request: request) }
                        Color.clear.frame(height: 1).id("cursor-bottom")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 250)
                .onAppear { proxy.scrollTo("cursor-bottom", anchor: .bottom) }
                .onChange(of: followLatest) { _, value in if value { proxy.scrollTo("cursor-bottom", anchor: .bottom) } }
                .onChange(of: entries) { _, _ in if followLatest { proxy.scrollTo("cursor-bottom", anchor: .bottom) } }
                .overlay(ConversationScrollObserver { followLatest = $0 }.allowsHitTesting(false))
            }
            if !followLatest { Button(L10n.text("回到最新消息")) { followLatest = true } }
            if let error = connection.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if connection.connected && !connection.loadedSessions.contains(session.id) {
                if connection.supportsLoad {
                    Button(L10n.text(connection.loadingSession ? "正在读取历史…" : "恢复 Cursor 会话")) { connection.load(session) }
                        .disabled(connection.loadingSession || connection.activeSessionID != nil)
                } else { Text(L10n.text("此 Cursor CLI 不支持恢复会话，请新建会话或更新 CLI。")).font(.caption).foregroundStyle(.secondary) }
            }
            ReplyEditor(text: $draft, enabled: connection.canSend(to: session.id), canSend: canSend, onSend: send)
                .frame(height: 55).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty { Text(L10n.text("回复 Cursor…")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(10).allowsHitTesting(false) }
                }
            HStack {
                Text(L10n.text("回车发送 · Shift＋回车换行")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(); Button(L10n.text("发送"), action: send).disabled(!canSend)
            }
        }.padding(16).frame(width: 400).background(Color(white: 0.09)).preferredColorScheme(.dark)
        .onAppear { connection.load(session); restoreFailedDraft() }
        .onChange(of: connection.connected) { _, value in if value { connection.load(session) } }
        .onChange(of: running) { _, value in
            if !value { restoreFailedDraft() }
        }
    }
}

struct CursorPermissionView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var connection = CursorConnection.shared
    let request: CursorPermission
    @State private var answers: [String: Set<String>] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Cursor 需要你的确认")).font(.headline)
            if request.method == "session/request_permission" {
                let tool = request.params["toolCall"] as? [String: Any] ?? [:]
                Text(tool["title"] as? String ?? "Cursor").font(.caption).textSelection(.enabled)
                if let input = tool["rawInput"], let data = try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed, .prettyPrinted]), let text = String(data: data, encoding: .utf8) {
                    Text(String(text.prefix(4096))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(Array((request.params["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, option in
                    let kind = option["kind"] as? String ?? ""
                    if ["allow_once", "reject_once"].contains(kind), let id = option["optionId"] as? String {
                        Button(L10n.text(kind == "allow_once" ? "仅允许本次" : "拒绝")) { connection.choose(request, optionID: id) }
                    }
                }
                Button(L10n.text("取消任务")) { connection.stop() }
            } else if request.method == "cursor/create_plan" {
                Text(String((request.params["plan"] as? String ?? "").prefix(8192))).font(.caption).textSelection(.enabled)
                HStack {
                    Button(L10n.text("确认计划")) { connection.respond(request, result: ["outcome": "accepted"]) }
                    Button(L10n.text("拒绝")) { connection.respond(request, result: ["outcome": "rejected"]) }
                }
            } else {
                let questions = request.params["questions"] as? [[String: Any]] ?? []
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    let id = question["id"] as? String ?? ""
                    Text(question["prompt"] as? String ?? "").font(.caption)
                    ForEach(Array((question["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, option in
                        let optionID = option["id"] as? String ?? ""
                        Button {
                            if question["allowMultiple"] as? Bool == true {
                                if answers[id, default: []].contains(optionID) { answers[id]?.remove(optionID) }
                                else { answers[id, default: []].insert(optionID) }
                            } else { answers[id] = [optionID] }
                        } label: {
                            Label(option["label"] as? String ?? optionID, systemImage: answers[id, default: []].contains(optionID) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
                Button(L10n.text("提交回答")) {
                    connection.respond(request, result: ["outcome": "answered", "answers": questions.map { ["questionId": $0["id"] as? String ?? "", "selectedOptionIds": Array(answers[$0["id"] as? String ?? "", default: []])] }])
                }.disabled(questions.isEmpty || questions.contains { answers[$0["id"] as? String ?? "", default: []].isEmpty })
                Button(L10n.text("取消任务")) { connection.stop() }
            }
        }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

