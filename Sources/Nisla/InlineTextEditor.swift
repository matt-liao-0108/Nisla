import SwiftUI
import AppKit

/// Only publish committed text, preserving IME composition and the current selection.
struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.appearance = NSAppearance(named: .darkAqua)
        let editor = ChecklistTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .white
        editor.backgroundColor = NSColor(white: 0.10, alpha: 1)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView,
              !editor.hasMarkedText(), editor.string != text else { return }
        let selections = editor.selectedRanges
        editor.string = text
        editor.selectedRanges = selections.map {
            let range = $0.rangeValue
            let location = min(range.location, editor.string.utf16.count)
            return NSValue(range: NSRange(location: location, length: min(range.length, editor.string.utf16.count - location)))
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextEditor
        init(_ parent: InlineTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            parent.text = editor.string
            parent.onCommit(editor.string)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            editor.unmarkText()
            parent.text = editor.string
            parent.onCommit(editor.string)
        }
    }
}

private final class ChecklistTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        let lineRange = (string as NSString).lineRange(for: selectedRange())
        let line = (string as NSString).substring(with: lineRange).trimmingCharacters(in: .newlines)
        super.insertNewline(sender)
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
            insertText("- [ ] ", replacementRange: selectedRange())
        }
    }
}
