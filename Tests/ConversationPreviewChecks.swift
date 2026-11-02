import SwiftUI
import AppKit

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

@main struct ConversationPreviewChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let originalLanguage = AppLocalization.shared.selection
        defer { AppLocalization.shared.selection = originalLanguage }
        AppLocalization.shared.selection = .simplifiedChinese
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NislaConversation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinStore(storageDirectory: folder,
            preferences: UserDefaults(suiteName: "NislaConversation-" + UUID().uuidString)!, interactive: false)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ConversationPreviews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func snapshot(_ name: String, message: String, internalKind: CodexSessionKind? = nil,
                      connection: CodexConnection? = nil, threadID: String? = nil) throws -> CGFloat {
            let session = CodexSession(id: threadID ?? "fixture-" + name, title: name == "review" ? "Guardian review" : "演示会话",
                project: "Fixture", modifiedAt: .now, isRunning: false,
                internalKind: internalKind, parentThreadID: internalKind == nil ? nil : "fixture-main")
            store.activities = [session.id: SessionActivity(phase: .completed, message: message)]
            let host = NSHostingView(rootView: AgentConversation(connection: connection ?? .shared, session: session).environmentObject(store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<4 {
                host.frame = NSRect(origin: .zero, size: NSSize(width: 400, height: host.fittingSize.height))
                window.setContentSize(host.frame.size)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            return host.frame.height
        }
        let short = try snapshot("short", message: "已经完成界面检查。")
        let review = try snapshot("review", message: #"{"risk_level":"low","user_authorization":"high","outcome":"allow","rationale":"只读取演示项目的数据，没有修改文件或提交内容。"}"#, internalKind: .review)
        let long = try snapshot("long", message: String(repeating: "这是一段演示消息，用于检查长内容是否在限定高度内滚动。\n", count: 100))
        let markdown = """
        已完成：

        - [下载 Nisla 通用安装包](/tmp/Nisla%20Demo/Nisla.zip)
        - [查看更新后的 README](/tmp/Nisla%20Demo/README.md)

        README 已补充 **Codex 连接**、回复、追加、停止，以及会话占用和退出旧版的处理步骤；包内说明也已同步。

        双架构编译、签名及压缩包校验通过。
        """
        let markdownHeight = try snapshot("markdown-log", message: markdown)
        precondition(markdownHeight < 420, "Formatted final reply must stay bounded without exposing long link destinations")
        precondition(short < 260, "A short message must not reserve a 200-point viewport")
        precondition(review < 420, "Review summary must remain compact")
        precondition(long < 600 && long > short, "Long messages must scroll within a bounded viewport")
        let pending = VStack(alignment: .leading, spacing: 12) {
            CodexChatRow(entry: CodexChatEntry(role: .user, text: "请继续完善旅行博客的首页。", state: .complete))
            CodexChatRow(entry: CodexChatEntry(role: .assistant, text: "", state: .waiting))
        }.padding(16).frame(width: 400).background(Color(white: 0.09)).environment(\.colorScheme, .dark)
        let pendingHost = NSHostingView(rootView: pending)
        let pendingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        pendingWindow.contentView = pendingHost
        pendingHost.frame = NSRect(origin: .zero, size: NSSize(width: 400, height: pendingHost.fittingSize.height))
        pendingHost.layoutSubtreeIfNeeded()
        let pendingBitmap = pendingHost.bitmapImageRepForCachingDisplay(in: pendingHost.bounds)!
        pendingHost.cacheDisplay(in: pendingHost.bounds, to: pendingBitmap)
        try pendingBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("pending-reply.png"))
        let formatted = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
            CodexChatRow(entry: CodexChatEntry(role: .assistant, text: markdown, state: .complete))
            ConversationMarkdown(source: "## 验证结果\n\n1. 检查中英文布局\n2. 保留 `Markdown` 格式\n\n```swift\nlet status = \"完成\"\n```\n\n| 检查 | 状态 |\n| --- | --- |\n| 编译 | 通过 |\n\n> 预览使用演示数据。")
        }.padding(16).frame(width: 400).background(Color(white: 0.09)).environment(\.colorScheme, .dark))
        let formattedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        formattedWindow.contentView = formatted
        for _ in 0..<4 {
            formatted.frame = NSRect(origin: .zero, size: NSSize(width: 400, height: formatted.fittingSize.height))
            formattedWindow.setContentSize(formatted.frame.size)
            formatted.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        precondition(formatted.frame.height < 850)
        let formattedBitmap = formatted.bitmapImageRepForCachingDisplay(in: formatted.bounds)!
        formatted.cacheDisplay(in: formatted.bounds, to: formattedBitmap)
        try formattedBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("markdown-reply.png"))
        let preferences = UserDefaults(suiteName: "NislaConversationConnection-" + UUID().uuidString)!
        let connection = CodexConnection(executableOverride: FileManager.default.currentDirectoryPath + "/Tests/mock_codex_interrupt.py", preferences: preferences)
        defer { connection.disconnect() }
        func pump(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(condition(), "Fixture connection timed out")
        }
        connection.connect()
        pump { connection.connected }
        connection.send("请继续完善旅行博客的首页。", to: "layout")
        pump { connection.conversations["layout"]?.last?.text == "Partial reply" }
        let language = AppLocalization.shared.selection
        defer { AppLocalization.shared.selection = language }
        for selected in [AppLanguage.simplifiedChinese, .english] {
            AppLocalization.shared.selection = selected
            let height = try snapshot("working-" + selected.rawValue, message: "", connection: connection, threadID: "layout")
            precondition(height < 360, "Active reply with stop control must fit a compact popup")
        }
        connection.stop("layout")
        pump { connection.activeTurns["layout"] == nil }
        let stoppedHeight = try snapshot("interrupted", message: "", connection: connection, threadID: "layout")
        precondition(stoppedHeight < 360)
        print("PASS: short/review/long conversation layouts are compact and bounded (\(Int(short))/\(Int(review))/\(Int(long)) pt); fixture data only")
        print("PASS: compact connected reply and interrupted states render in Chinese and English using a protocol fixture; no real Codex service")
        print("PASS: Markdown log and assistant reply render links, lists, bold, code and tables using fixture content; no links opened")
    }
}
