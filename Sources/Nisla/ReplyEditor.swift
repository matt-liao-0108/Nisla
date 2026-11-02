import SwiftUI
import AppKit

/// A multiline composer: Return sends, Shift-Return inserts a line break.
struct ReplyEditor: NSViewRepresentable {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding var text: String
    var enabled: Bool
    var canSend: Bool
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = ReplyTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(L10n.text("回复或发送后续指令，回车发送，Shift 加回车换行"))
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ReplyTextView else { return }
        _ = localization.selection
        editor.setAccessibilityLabel(L10n.text("回复或发送后续指令，回车发送，Shift 加回车换行"))
        editor.isEditable = enabled
        editor.submit = { [weak editor, weak coordinator = context.coordinator] in
            // Read the current representable, not an earlier draft captured during construction.
            guard let editor, let parent = coordinator?.parent else { return }
            guard parent.enabled, parent.canSend else { return }
            parent.text = editor.string
            parent.onSend()
        }
        if !editor.hasMarkedText(), editor.string != text {
            editor.string = text
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReplyEditor
        init(_ parent: ReplyEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            parent.text = editor.string
        }
    }
}

final class ReplyTextView: NSTextView {
    var submit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText(), !event.modifierFlags.contains(.shift) {
            if isEditable { submit?() }
            return
        }
        super.keyDown(with: event)
    }
}
