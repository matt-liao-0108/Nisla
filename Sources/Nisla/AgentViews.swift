import SwiftUI

struct AgentSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var connection = CodexConnection.shared
    @State private var exporting = false
    var body: some View {
        Form {
            Section(L10n.text("Codex 连接")) {
                Text(L10n.text(connection.status)).font(.caption).textSelection(.enabled)
                TextField(L10n.text("Codex 可执行文件路径"), text: $connection.executable).disabled(connection.connecting)
                Picker(L10n.text("连接模式"), selection: $connection.transport) {
                    Text(L10n.text("现有本地服务（共享活动）")).tag("proxy")
                    Text(L10n.text("独立 CLI 服务（继续已保存会话）")).tag("direct")
                }.disabled(connection.connecting)
                TextField(L10n.text("控制 Socket（留空使用 Codex 默认）"), text: $connection.socket)
                    .disabled(connection.transport == "direct" || connection.connecting)
                HStack {
                    Button(connection.connecting ? L10n.text("正在连接…") : L10n.text("连接 / 重连")) { connection.connect() }.disabled(connection.connecting)
                    Button(L10n.text("断开")) { connection.disconnect() }.disabled(!connection.connected && !connection.connecting)
                    Button(L10n.text("刷新额度")) { connection.refresh() }.disabled(!connection.connected)
                }
                if connection.canOfferDirectConnection {
                    Text(L10n.text("独立服务不会接管桌面 Codex 正在运行的任务，也不会自动发送消息。")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("使用独立服务连接")) { connection.connectIndependently() }
                }
                Text(L10n.text("连接正在运行的 Codex 本地服务。握手成功后才启用回复、问答与支持的审批；不会自动启动模型任务。")).font(.caption).foregroundStyle(.secondary)
                if connection.transport == "direct" {
                    Text(L10n.text("独立服务只能处理在 Nisla 中发起的轮次，不会接管其他窗口里已运行的任务和审批。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.text("额度")) { Text(L10n.text(connection.quota)).font(.caption).textSelection(.enabled) }
            Section(L10n.text("连接诊断")) {
                Text(connection.diagnostics.suffix(10).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Button(L10n.text("复制诊断")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connection.status + "\n" + connection.diagnostics.joined(separator: "\n"), forType: .string)
                }
                Button(L10n.text("导出诊断…")) {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Nisla-Codex-diagnostics.txt"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? (connection.status + "\n" + connection.diagnostics.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct AgentRequestView: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var connection = CodexConnection.shared
    let request: AgentRequest
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.method.contains("requestUserInput") ? L10n.text("Codex 需要你的回答") : L10n.text("Codex 请求审批")).font(.headline)
            Text(request.description).font(.caption).textSelection(.enabled)
            if let command = request.parameters["command"] as? String { Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
            if let cwd = request.parameters["cwd"] as? String { Text(cwd).font(.caption2).foregroundStyle(.secondary) }
            if request.method == "item/tool/requestUserInput", let questions = request.parameters["questions"] as? [[String: Any]] {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                    let id = q["id"] as? String ?? ""
                    Text(q["question"] as? String ?? L10n.text("问题")).font(.caption)
                    if let options = q["options"] as? [[String: Any]] {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            let label = option["label"] as? String ?? ""
                            Button { answers[id] = label } label: {
                                Label(label, systemImage: answers[id] == label ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    TextField(L10n.text("输入回答"), text: Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }))
                }
                Button(L10n.text("提交回答")) {
                    let result = answers.mapValues { ["answers": [$0]] }
                    connection.respond(request, result: ["answers": result])
                }.disabled(questions.contains { answers[$0["id"] as? String ?? "", default: ""].isEmpty })
            } else {
                HStack {
                    Button(L10n.text("仅允许本次")) { connection.respond(request, result: ["decision": "accept"]) }
                    Button(L10n.text("拒绝"), role: .destructive) { connection.respond(request, result: ["decision": "decline"]) }
                    Button(L10n.text("取消任务")) { connection.respond(request, result: ["decision": "cancel"]) }
                }
            }
        }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AgentConversation: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject var store: PinStore
    @ObservedObject var connection = CodexConnection.shared
    let session: CodexSession
    @State private var draft = ""
    @State private var contentHeight: CGFloat = 60
    @State private var showRawReview = false
    private var message: String { connection.messages[session.id] ?? store.activities[session.id]?.message ?? L10n.text("暂无消息") }
    private var isInternal: Bool { session.internalKind != nil }
    private var isStopping: Bool { connection.stoppingThreads.contains(session.id) }
    private var isRunning: Bool { connection.activeTurns[session.id] != nil }
    private var canReply: Bool {
        connection.threadErrors[session.id] == nil && !connection.checkingThreads.contains(session.id) && !isStopping
    }
    private var canSend: Bool { canReply && !connection.sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var phaseTitle: String? {
        if isStopping { return "正在停止…" }
        if connection.sendingThreads.contains(session.id) { return "发送中…" }
        if isRunning { return "正在处理" }
        if let last = connection.conversations[session.id]?.last, last.role == .assistant {
            switch last.state {
            case .interrupted: return "已中断"
            case .complete: return "已完成"
            case .failed: return "未收到回复"
            default: break
            }
        }
        return store.activities[session.id]?.phase.title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.headline).lineLimit(2)
                    if let phaseTitle { Text(L10n.text(phaseTitle)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if !isInternal && connection.canStop(session.id) {
                    Button { connection.stop(session.id) } label: {
                        Label(L10n.text(isStopping ? "正在停止…" : "停止"), systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .medium))
                    }.disabled(isStopping)
                    .accessibilityLabel(L10n.text("停止当前任务"))
                }
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isInternal, let entries = connection.conversations[session.id], !entries.isEmpty {
                        ForEach(entries) { entry in CodexChatRow(entry: entry, project: session.project) }
                    } else if let review = ReviewSummary.parse(message) {
                        Text(L10n.text("审查结果（只读）")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(L10n.text(review.riskLabel))
                            Text("·").foregroundStyle(.secondary)
                            Text(L10n.text(review.outcomeLabel))
                            Spacer()
                        }.font(.system(size: 12, weight: .semibold))
                        Text(L10n.text(review.authorizationLabel)).font(.caption).foregroundStyle(.secondary)
                        Text(review.rationale).font(.system(size: 12)).textSelection(.enabled)
                        DisclosureGroup(L10n.text("查看原始 JSON"), isExpanded: $showRawReview) {
                            Text(message).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                    } else {
                        ConversationMarkdown(source: message, project: session.project).equatable()
                    }
                    if !isInternal {
                        ForEach(connection.requests.filter { $0.threadID == session.id }) { request in AgentRequestView(request: request) }
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ConversationContentHeight.self, value: geometry.size.height)
                })
            }.frame(height: min(220, max(30, contentHeight)))
                .onPreferenceChange(ConversationContentHeight.self) { contentHeight = $0 }
                .onAppear { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                .onChange(of: connection.conversations[session.id]?.last?.id) { _, _ in proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                .onChange(of: connection.conversations[session.id]?.last?.text.count) { _, _ in proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            if store.activities[session.id]?.phase == .unknown {
                Button(L10n.text("重新查找会话记录")) { store.refreshCodex() }
            }
            if isInternal {
                Text(L10n.text("内部会话仅供查看，请在主会话中继续。")).font(.caption).foregroundStyle(.secondary)
            } else if connection.connected {
                if let error = connection.stopErrors[session.id] {
                    Label(L10n.text(error), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let error = connection.threadErrors[session.id] {
                    Label(L10n.text(error), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button(connection.checkingThreads.contains(session.id) ? L10n.text("正在检查…") : L10n.text("重新检查会话")) { connection.follow(session.id) }
                        .disabled(connection.checkingThreads.contains(session.id))
                }
                ReplyEditor(text: $draft,
                            enabled: canReply,
                            canSend: canSend) {
                    connection.send(draft, to: session.id)
                }
                .frame(height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(L10n.text(isRunning ? "补充指令…" : "回复 Codex…"))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 12).padding(.vertical, 9).allowsHitTesting(false)
                    }
                }
                HStack {
                    Text(connection.checkingThreads.contains(session.id) ? L10n.text("正在检查会话是否可回复…") : L10n.text("回车发送 · Shift＋回车换行"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text(connection.sendingThreads.contains(session.id) ? "发送中…" : isRunning ? "追加" : "发送")) { connection.send(draft, to: session.id) }
                        .disabled(!canSend)
                }
            } else {
                Text(L10n.text(connection.status)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(connection.connecting ? L10n.text("正在连接…") : L10n.text("连接 Codex")) { connection.connect() }.disabled(connection.connecting)
                if connection.canOfferDirectConnection {
                    Text(L10n.text("独立服务不会接管桌面 Codex 正在运行的任务，也不会自动发送消息。")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("使用独立服务连接")) { connection.connectIndependently() }
                }
            }
            if let threadID = isInternal ? session.parentThreadID : session.id {
                Button(isInternal ? L10n.text("打开主会话") : L10n.text("在 Codex 中继续")) {
                    if let url = URL(string: "codex://threads/\(threadID)"), !NSWorkspace.shared.open(url) { store.notice = L10n.text("无法打开 Codex") }
                }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(width: 400).background(Color(white: 0.09)).preferredColorScheme(.dark)
        .onAppear { if !isInternal { connection.follow(session.id) } }
        .onChange(of: connection.connected) { _, connected in if connected && !isInternal { connection.follow(session.id) } }
        .onChange(of: connection.lastSendSucceeded) { _, success in
            if success && connection.lastSentThreadID == session.id && connection.lastSentText == draft { draft = "" }
        }
    }
}

struct CodexChatRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    let entry: CodexChatEntry
    var project = ""
    private var status: String {
        switch entry.state {
        case .sending: "发送中…"
        case .waiting: "等待 Codex 回复…"
        case .streaming: "正在回复…"
        case .complete: entry.role == .user ? "已发送" : "已完成"
        case .failed: entry.role == .user ? "发送失败，草稿已保留" : "未收到回复"
        case .interrupted: "连接或任务已中断"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.role == .user ? L10n.text("你") : "Codex").fontWeight(.semibold)
                Spacer()
                if [.sending, .waiting, .streaming].contains(entry.state) {
                    ProgressView().controlSize(.mini)
                }
                if entry.state != .complete {
                    Text(L10n.text(status)).foregroundStyle(entry.state == .failed ? Color.orange : .secondary)
                }
            }.font(.system(size: 10))
            if !entry.text.isEmpty {
                if entry.role == .assistant {
                    ConversationMarkdown(source: entry.text, project: project).equatable()
                } else {
                    Text(entry.text).font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if entry.state == .complete {
                Text(L10n.text("本轮已结束，未返回文本。")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10)
        .background(entry.role == .user ? Color.mint.opacity(0.12) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ConversationContentHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
