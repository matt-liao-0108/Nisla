import SwiftUI

struct AgentSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject var connection = CodexConnection.shared
    @State private var exporting = false
    var body: some View {
        Form {
            Section(L10n.text("Codex 连接")) {
                Text(L10n.text(connection.status)).font(.caption).textSelection(.enabled)
                TextField(L10n.text("Codex 可执行文件路径"), text: $connection.executable)
                Picker(L10n.text("连接模式"), selection: $connection.transport) {
                    Text(L10n.text("现有本地服务（共享活动）")).tag("proxy")
                    Text(L10n.text("独立 CLI 服务（继续已保存会话）")).tag("direct")
                }
                TextField(L10n.text("控制 Socket（留空使用 Codex 默认）"), text: $connection.socket)
                HStack {
                    Button(L10n.text("连接 / 重连")) { connection.connect() }
                    Button(L10n.text("断开")) { connection.disconnect() }.disabled(!connection.connected)
                    Button(L10n.text("刷新额度")) { connection.refresh() }.disabled(!connection.connected)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.title).font(.headline).lineLimit(2)
            if let activity = store.activities[session.id] { Text(L10n.text(activity.phase.title)).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(connection.messages[session.id] ?? store.activities[session.id]?.message ?? L10n.text("暂无消息"))
                        .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(connection.requests.filter { $0.threadID == session.id }) { request in AgentRequestView(request: request) }
                }
            }.frame(height: store.activities[session.id]?.phase == .unknown && connection.messages[session.id] == nil ? 70 : 200)
            if store.activities[session.id]?.phase == .unknown {
                Button(L10n.text("重新查找会话记录")) { store.refreshCodex() }
            }
            if connection.connected {
                if let error = connection.threadErrors[session.id] {
                    Label(L10n.text(error), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button(connection.checkingThreads.contains(session.id) ? L10n.text("正在检查…") : L10n.text("重新检查会话")) { connection.follow(session.id) }
                        .disabled(connection.checkingThreads.contains(session.id))
                }
                ReplyEditor(text: $draft,
                            enabled: connection.threadErrors[session.id] == nil && !connection.checkingThreads.contains(session.id),
                            canSend: !connection.sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    connection.send(draft, to: session.id)
                }
                .frame(height: 70).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(connection.checkingThreads.contains(session.id) ? L10n.text("正在检查会话是否可回复…") : connection.threadErrors[session.id] == nil ? L10n.text(connection.status) : L10n.text("草稿保留，未发送"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack {
                    Text(L10n.text("回车发送 · Shift＋回车换行")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button(connection.sending ? L10n.text("发送中…") : L10n.text("发送")) { connection.send(draft, to: session.id) }
                        .disabled(connection.sending || connection.threadErrors[session.id] != nil || connection.checkingThreads.contains(session.id) || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else { Text(L10n.text("在设置 → Agent 中连接 Codex，可在这里回复与处理支持的审批。")).font(.caption).foregroundStyle(.secondary) }
            Button(L10n.text("在 Codex 中继续")) {
                if let url = URL(string: "codex://threads/\(session.id)"), !NSWorkspace.shared.open(url) { store.notice = L10n.text("无法打开 Codex") }
            }
        }.padding(16).frame(width: 400).background(Color(white: 0.09)).preferredColorScheme(.dark)
        .onAppear { connection.follow(session.id) }
        .onChange(of: connection.connected) { _, connected in if connected { connection.follow(session.id) } }
        .onChange(of: connection.lastSendSucceeded) { _, success in
            if success && connection.lastSentThreadID == session.id && connection.lastSentText == draft { draft = "" }
        }
    }
}
