import SwiftUI
import AppKit

/// Foundation supplies the Markdown grammar and inline attributes. Keep block
/// semantics too: SwiftUI Text alone does not lay out lists or code fences.
struct ConversationMarkdownDocument {
    struct Block: Identifiable {
        let id: Int
        let intent: [PresentationIntent.IntentType]
        var text: AttributedString
        var marker: String?
        var depth: Int = 0
        var quoted: Bool { intent.contains { $0.kind == .blockQuote } }
        var tableID: Int? {
            intent.first { if case .table = $0.kind { return true }; return false }?.identity
        }
        var rowID: Int? {
            intent.first {
                if case .tableRow = $0.kind { return true }
                return $0.kind == .tableHeaderRow
            }?.identity
        }
        var isTableHeader: Bool { intent.contains { $0.kind == .tableHeaderRow } }
        var kind: PresentationIntent.Kind { intent.first?.kind ?? .paragraph }
    }
    struct Section: Identifiable {
        let id: Int
        var blocks: [Block]
        var isTable: Bool { blocks.first?.tableID != nil }
    }
    let sections: [Section]

    init(_ source: String, project: String = "") {
        let source = String(source.prefix(65_536))
        guard let parsed = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            sections = [Section(id: 0, blocks: [Block(id: 0, intent: [], text: AttributedString(source))])]
            return
        }
        var blocks: [Block] = []
        for run in parsed.runs {
            let intent = run.presentationIntent?.components ?? []
            let identity = intent.first?.identity ?? 0
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            // Images remain their textual alternative, never automatic network loads.
            text.imageURL = nil
            if let link = run.link { text.link = ConversationLink.destination(link, project: project) }
            if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .system(size: 11, design: .monospaced)
                text.backgroundColor = Color.white.opacity(0.07)
            }
            if blocks.last?.id == identity { blocks[blocks.count - 1].text.append(text) }
            else { blocks.append(Block(id: identity, intent: intent, text: text)) }
        }
        var listItems: Set<Int> = []
        for index in blocks.indices {
            let intent = blocks[index].intent
            blocks[index].depth = intent.filter {
                $0.kind == .orderedList || $0.kind == .unorderedList
            }.count
            if let item = intent.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = intent[item].kind,
               listItems.insert(intent[item].identity).inserted {
                let container = intent.dropFirst(item + 1).first {
                    $0.kind == .orderedList || $0.kind == .unorderedList
                }
                blocks[index].marker = container?.kind == .orderedList ? "\(ordinal)." : "•"
            }
        }
        var sections: [Section] = []
        for block in blocks {
            if let table = block.tableID, sections.last?.blocks.first?.tableID == table {
                sections[sections.count - 1].blocks.append(block)
            } else { sections.append(Section(id: block.id, blocks: [block])) }
        }
        self.sections = sections
    }
}

enum ConversationLink {
    /// Only explicit clicks open links. File links reveal a file, never execute it.
    static func destination(_ url: URL, project: String = "") -> URL? {
        if let scheme = url.scheme?.lowercased() {
            if ["https", "http"].contains(scheme), url.host?.isEmpty == false { return url }
            if scheme == "file", url.host == nil || url.host == "" || url.host == "localhost" { return url }
            return nil
        }
        guard url.host == nil, !url.path.isEmpty else { return nil }
        if url.path.hasPrefix("/") { return URL(fileURLWithPath: url.path) }
        guard project.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: project, isDirectory: true).appendingPathComponent(url.path).standardizedFileURL
    }

    static func fileToReveal(_ url: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        guard url.isFileURL else { return nil }
        if exists(url.path) { return url }
        // Codex file references sometimes append :line or :line:column.
        let path = url.path.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
        return path != url.path && exists(path) ? URL(fileURLWithPath: path) : nil
    }
}

struct ConversationMarkdown: View, Equatable {
    @ObservedObject private var localization = AppLocalization.shared
    let source: String
    let project: String
    @State private var missingFile = false
    init(source: String, project: String = "") { self.source = source; self.project = project }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source && lhs.project == rhs.project }

    var body: some View {
        let document = ConversationMarkdownDocument(source, project: project)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.sections) { section in
                if section.isTable { table(section.blocks) }
                else if let block = section.blocks.first { blockView(block) }
            }
            if missingFile {
                Text(L10n.text("链接指向的本地文件不存在或无法访问"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
        .tint(Color(red: 0.55, green: 0.72, blue: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = ConversationLink.destination(url, project: project) else { return .discarded }
            if destination.isFileURL {
                if let file = ConversationLink.fileToReveal(destination) {
                    missingFile = false
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else { missingFile = true }
                return .handled
            }
            return .systemAction(destination)
        })
    }

    @ViewBuilder private func blockView(_ block: ConversationMarkdownDocument.Block) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if block.depth > 0 {
                Text(block.marker ?? "").foregroundStyle(.secondary)
                    .frame(minWidth: 13, alignment: .trailing)
            }
            if block.quoted { Rectangle().fill(.white.opacity(0.25)).frame(width: 2) }
            switch block.kind {
            case .header(let level):
                Text(block.text).font(.system(size: level == 1 ? 16 : 14, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .codeBlock(let language): code(block.text, language: language)
            case .thematicBreak: Divider()
            default:
                Text(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, CGFloat(max(0, min(block.depth - 1, 5))) * 14)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ text: AttributedString, language: String?) -> some View {
        let plain = String(text.characters)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language ?? L10n.text("代码")).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plain, forType: .string)
                } label: { Label(L10n.text("复制"), systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.system(size: 10))
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: plain).font(.system(size: 11, design: .monospaced))
                        .fixedSize().frame(minWidth: geometry.size.width, alignment: .leading)
                }
            }.frame(height: min(160, CGFloat(max(1, lines)) * 16))
        }.padding(10).background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func table(_ blocks: [ConversationMarkdownDocument.Block]) -> some View {
        let rowIDs = blocks.reduce(into: [Int]()) { rows, block in
            if let id = block.rowID, rows.last != id { rows.append(id) }
        }
        return ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rowIDs, id: \.self) { row in
                    GridRow {
                        ForEach(blocks.filter { $0.rowID == row }) { cell in
                            Text(cell.text).font(.system(size: 11, weight: cell.isTableHeader ? .semibold : .regular))
                                .frame(width: 140, alignment: .leading).padding(8)
                                .background(.white.opacity(cell.isTableHeader ? 0.08 : 0.03))
                        }
                    }
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
