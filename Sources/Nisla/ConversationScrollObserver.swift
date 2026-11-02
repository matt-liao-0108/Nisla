import SwiftUI
import AppKit

/// Observe user scrolling only. Programmatic scrollTo must not disable following.
struct ConversationScrollObserver: NSViewRepresentable {
    var onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor(onScroll: onScroll) }
    func updateNSView(_ view: Anchor, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class Anchor: NSView {
        var onScroll: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(onScroll: @escaping (Bool) -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard observers.isEmpty else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                        observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self, weak scroll] notification in
                            let starting = notification.name == NSScrollView.willStartLiveScrollNotification
                            MainActor.assumeIsolated {
                                guard let self, let scroll else { return }
                                if starting { self.onScroll(false); return }
                                self.onScroll(Self.isAtBottom(scroll))
                            }
                        })
                    }
                    return
                }
                ancestor = view.superview
            }
        }
        static func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            let visible = scroll.documentVisibleRect
            let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            return remaining <= 24
        }
        func detach() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll() }
    }
}
