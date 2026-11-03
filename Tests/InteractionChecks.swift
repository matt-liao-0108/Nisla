import AppKit
import SwiftUI

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

@main struct InteractionChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NislaInteraction-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PinStore(storageDirectory: folder, preferences: UserDefaults(suiteName: "NislaInteraction-" + UUID().uuidString)!, interactive: false)
        let root = NSWindow(contentRect: NSRect(x: 100, y: 500, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        let popover = NSWindow(contentRect: NSRect(x: 180, y: 220, width: 260, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        root.contentView = NSView(frame: root.contentLayoutRect); popover.contentView = NSView(frame: popover.contentLayoutRect)
        root.orderFront(nil); popover.orderFront(nil)
        defer { root.orderOut(nil); popover.orderOut(nil) }
        let regions = ShelfInteractionRegions()
        regions.add(root.contentView!); regions.add(popover.contentView!)
        let monitor = ShelfOutsideClickMonitor(regions: regions)
        store.isExpanded = true; store.previewOpen = true
        for point in [CGPoint(x: 230, y: 300), CGPoint(x: 230, y: 550)] {
            monitor.handle(point: point, store: store)
            precondition(store.isExpanded && store.previewOpen)
        }
        let dismissal = store.previewDismissal
        monitor.handle(point: CGPoint(x: 10, y: 10), store: store)
        precondition(!store.isExpanded && !store.previewOpen && store.previewDismissal == dismissal + 1)
        store.isExpanded = true; store.previewOpen = true; store.keepOpen = true
        monitor.handle(point: CGPoint(x: 10, y: 10), store: store)
        precondition(store.isExpanded && !store.previewOpen)
        store.keepOpen = false; store.previewOpen = true
        regions.add(popover.contentView!, preview: true)
        monitor.handle(point: CGPoint(x: 10, y: 10), store: store)
        precondition(store.isExpanded && store.isClosingPreview && !store.previewOpen)
        monitor.handle(point: CGPoint(x: 230, y: 550), store: store)
        precondition(store.isExpanded && !store.isClosingPreview, "Clicking back inside cancels the pending collapse")
        regions.remove(popover.contentView!)
        regions.add(popover.contentView!)
        store.keepOpen = true
        store.keepOpen = false; store.previewOpen = true
        monitor.handle(point: CGPoint(x: 10, y: 10), store: store, blocked: true)
        precondition(store.isExpanded && store.previewOpen)
        store.editingNoteID = UUID()
        monitor.handle(point: CGPoint(x: 10, y: 10), store: store)
        precondition(store.isExpanded && store.previewOpen)
        store.editingNoteID = nil; popover.orderOut(nil)
        monitor.handle(point: CGPoint(x: 230, y: 300), store: store)
        precondition(!store.isExpanded && !store.previewOpen)
        print("PASS: real window bounds handle shelf/popover/outside clicks, hidden windows, pin and modal/editor protections")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document; root.contentView = scroll
        var following: [Bool] = []
        let anchor = ConversationScrollObserver.Anchor { following.append($0) }
        document.addSubview(anchor)
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        scroll.contentView.scroll(to: .zero)
        precondition(following.isEmpty)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        precondition(following.last == false)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 800))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        precondition(following.last == true)
        anchor.detach()
        print("PASS: native scroll notifications pause following when reading history and resume at the bottom; no real input events sent")
        var draft = "", saved = ""
        let composer = InlineTextEditor(text: Binding(get: { draft }, set: { draft = $0 })) { saved = $0 }
        let coordinator = InlineTextEditor.Coordinator(composer)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        editor.setMarkedText("输入中的演示便签", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: editor))
        precondition(!editor.hasMarkedText() && saved == "输入中的演示便签" && draft == saved)
        store.previewOpen = true
        let cursorDismissal = store.previewDismissal
        store.agentProvider = "cursor"
        precondition(!store.previewOpen && store.previewDismissal > cursorDismissal, "Provider changes must dismiss the previous preview")
        store.selectedTab = 1
        store.cursorSessionCount = 4
        precondition(store.bodyHeight >= 200)
        store.agentProvider = "codex"
        print("PASS: ending note editing commits remaining IME text before popover dismissal")
    }
    final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
}
