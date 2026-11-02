import Foundation
import SwiftUI

@main struct MarkdownChecks {
    static func main() {
        let source = """
        已完成：

        - [下载 Nisla 通用安装包](/tmp/Nisla%20Demo/Nisla.zip)
        - [查看更新后的 README](/tmp/Nisla%20Demo/README.md)

        README 已补充 **Codex 连接**、回复、追加、停止。

        双架构编译、签名及压缩包校验通过。
        """
        let sections = ConversationMarkdownDocument(source).sections
        precondition(sections.count == 5)
        let blocks = sections.flatMap(\.blocks)
        precondition(String(blocks[1].text.characters) == "下载 Nisla 通用安装包")
        precondition(blocks[1].marker == "•" && blocks[2].marker == "•")
        let download = blocks[1].text.runs.compactMap(\.link).first!
        precondition(download.isFileURL && download.path == "/tmp/Nisla Demo/Nisla.zip")
        precondition(blocks[3].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        precondition(!blocks.contains { String($0.text.characters).contains("/tmp/") })
        print("PASS: screenshot-style response renders labels, file links, bullets, paragraphs and bold without exposing Markdown syntax or file paths")

        let complex = ConversationMarkdownDocument("""
        ## Results

        3. First
           - Nested **item**
        4. Second

        > A quote with `inline code`.

        ```swift
        let text = "[not a link](https://example.com)"
        ```

        | Item | Result |
        | --- | --- |
        | Build | **Passed** |
        """).sections
        let flattened = complex.flatMap(\.blocks)
        precondition(flattened.first?.kind == .header(level: 2))
        precondition(flattened.contains { $0.marker == "3." })
        precondition(flattened.contains { $0.marker == "•" && $0.depth == 2 })
        precondition(flattened.contains { $0.marker == "4." })
        precondition(flattened.contains { $0.quoted })
        let code = flattened.first { if case .codeBlock = $0.kind { return true }; return false }!
        precondition(String(code.text.characters).contains("[not a link](https://example.com)"))
        precondition(code.text.runs.allSatisfy { $0.link == nil })
        let table = complex.first { $0.isTable }!
        precondition(table.blocks.count == 4 && table.blocks.filter(\.isTableHeader).count == 2)
        print("PASS: native Markdown block semantics preserve headings, ordered/nested lists, quotes, literal code and tables")

        for scheme in ["javascript:alert(1)", "data:text/plain,test", "codex://threads/example", "file://remote-host/share/file"] {
            precondition(ConversationLink.destination(URL(string: scheme)!) == nil)
        }
        precondition(ConversationLink.destination(URL(string: "https://example.com/docs")!)?.scheme == "https")
        precondition(ConversationLink.destination(URL(string: "Sources/App.swift")!, project: "/tmp/Fixture")?.path == "/tmp/Fixture/Sources/App.swift")
        precondition(ConversationLink.destination(URL(string: "README.md")!) == nil)
        let lineReference = URL(fileURLWithPath: "/tmp/Fixture/App.swift:12:3")
        precondition(ConversationLink.fileToReveal(lineReference, exists: { $0 == "/tmp/Fixture/App.swift" })?.path == "/tmp/Fixture/App.swift")
        precondition(ConversationLink.fileToReveal(lineReference, exists: { _ in false }) == nil)
        precondition(ConversationLink.fileToReveal(lineReference, exists: { $0 == lineReference.path }) == lineReference)
        let image = ConversationMarkdownDocument("![A descriptive alternative](https://example.com/image.png)").sections.flatMap(\.blocks)
        precondition(image.allSatisfy { $0.text.runs.allSatisfy { $0.imageURL == nil } })
        print("PASS: relative/file links resolve without opening anything, missing files and line references are handled, unsupported schemes and image fetching are excluded")

        for partial in ["**unfinished", "[Download](/tmp/unfinished", "```swift\nlet value =", "", "plain text", "a\nb"] {
            let document = ConversationMarkdownDocument(partial)
            precondition(document.sections.flatMap(\.blocks).allSatisfy { $0.text.characters.count <= 65_536 })
        }
        let long = ConversationMarkdownDocument(String(repeating: "x", count: 100_000)).sections.flatMap(\.blocks)
        precondition(long.reduce(0) { $0 + $1.text.characters.count } == 65_536)
        print("PASS: incomplete streaming Markdown and plain text parse without crashing; input size remains bounded")
    }
}
