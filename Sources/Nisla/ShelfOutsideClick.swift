import SwiftUI
import AppKit

/// Register real view bounds, including detached SwiftUI popovers. Do not treat
/// unrelated app windows (for example Settings) as part of the shelf.
@MainActor final class ShelfInteractionRegions {
    static let shared = ShelfInteractionRegions()
    private let views = NSHashTable<NSView>.weakObjects()
    private let previewViews = NSHashTable<NSView>.weakObjects()
    func add(_ view: NSView, preview: Bool = false) {
        views.add(view)
        if preview { previewViews.add(view) }
    }
    func remove(_ view: NSView) { views.remove(view); previewViews.remove(view) }
    var windows: [NSWindow] { views.allObjects.compactMap(\.window).filter(\.isVisible) }
    var previewWindows: [NSWindow] { previewViews.allObjects.compactMap(\.window).filter(\.isVisible) }
    func contains(_ point: NSPoint) -> Bool {
        views.allObjects.contains { view in
            guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return false }
            return window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
    }
}

struct ShelfInteractionBoundary: NSViewRepresentable {
    var preview = false
    func makeNSView(context: Context) -> Boundary {
        let view = Boundary()
        ShelfInteractionRegions.shared.add(view, preview: preview)
        return view
    }
    func updateNSView(_ view: Boundary, context: Context) {}
    static func dismantleNSView(_ view: Boundary, coordinator: ()) { ShelfInteractionRegions.shared.remove(view) }
    final class Boundary: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}

@MainActor final class ShelfOutsideClickMonitor: NSObject {
    static let shared = ShelfOutsideClickMonitor()
    private let regions: ShelfInteractionRegions
    private var global: Any?
    private var local: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = 0
    private weak var pendingStore: PinStore?
    private var pendingWindows: [NSWindow] = []
    private var closingPopovers: [ObjectIdentifier: Int] = [:]
    private var observedClosingPopovers: [ObjectIdentifier: NSWindow] = [:]
    private let previousAnimations = NSMapTable<NSPopover, NSNumber>.weakToStrongObjects()
    private var remainingWindowNumbers = Set<Int>()
    private var closeTimeout: Task<Void, Never>?
    private var pendingForceCollapse = false
    private var observingPopovers = false
    init(regions: ShelfInteractionRegions = .shared) { self.regions = regions; super.init() }

    func start(store: PinStore, blocked: @escaping () -> Bool) {
        stop()
        observePopoverLifecycle()
        // Mouse buttons only; no keyboard monitoring, event tap, or permission.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.handle(point: NSEvent.mouseLocation, store: store, blocked: blocked())
            }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak store] event in
            MainActor.assumeIsolated {
                if let self, let store {
                    let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                    self.handle(point: point, store: store, blocked: blocked())
                }
            }
            return event // Deliver the original click to its target.
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let began = notification.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated { self?.trackingMenus = max(0, (self?.trackingMenus ?? 0) + (began ? 1 : -1)) }
            })
        }
    }

    func handle(point: NSPoint, store: PinStore, blocked: Bool = false) {
        if regions.contains(point) { cancelPendingCollapse(); return }
        // Repeated outside clicks must not start shrinking while the first
        // preview is still completing its close animation.
        if pendingStore === store { return }
        guard store.isExpanded || store.previewOpen,
              !blocked, trackingMenus == 0, !store.isResizingWidth,
              store.editingNoteID == nil, store.notice == nil else { return }
        requestCollapse(store: store, force: false)
    }

    func requestCollapse(store: PinStore, force: Bool) {
        if pendingStore === store {
            if force { pendingForceCollapse = true }
            return
        }
        let shouldCollapse = force || !store.keepOpen
        // A transient popover may start closing as the other app receives the
        // click, before our global click monitor is called. Keep tracking that
        // window until AppKit reports its animation has finished.
        var previews = shouldCollapse ? regions.previewWindows : []
        if shouldCollapse {
            for window in observedClosingPopovers.values where !previews.contains(where: { $0 === window }) {
                previews.append(window)
            }
        }
        if !previews.isEmpty { waitForPreviewClose(store: store, windows: previews, force: force) }
        // End text editing before removing a popover so its committed draft is saved.
        regions.windows.forEach { $0.makeFirstResponder(nil) }
        store.dismissPreviews()
        if shouldCollapse && previews.isEmpty { store.isExpanded = false }
    }

    private func waitForPreviewClose(store: PinStore, windows: [NSWindow], force: Bool) {
        cancelPendingCollapse()
        observePopoverLifecycle()
        pendingStore = store
        pendingWindows = windows
        pendingForceCollapse = force
        remainingWindowNumbers = Set(windows.map(\.windowNumber))
        for (identifier, window) in observedClosingPopovers where remainingWindowNumbers.contains(window.windowNumber) {
            closingPopovers[identifier] = window.windowNumber
        }
        store.isClosingPreview = true
        closeTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            // If AppKit omits its completion callback, hide the already
            // dismissed preview before allowing its anchor to shrink.
            self.pendingWindows.filter(\.isVisible).forEach { $0.orderOut(nil) }
            self.finishPendingCollapse()
        }
    }

    func observePopoverLifecycle() {
        guard !observingPopovers else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(popoverDidShow(_:)), name: NSPopover.didShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverWillClose(_:)), name: NSPopover.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: nil)
        observingPopovers = true
    }

    @objc private func popoverDidShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              let window = popover.contentViewController?.view.window,
              regions.previewWindows.contains(where: { $0 === window }) else { return }
        // The system keeps the parent window's displayed bounds frozen while
        // its anchored popover shrinks. Close the preview immediately so the
        // panel can start its own anchored animation in the same interaction.
        disableCloseAnimation(for: popover)
    }

    @objc private func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              let window = popover.contentViewController?.view.window else { return }
        let identifier = ObjectIdentifier(popover)
        let number = window.windowNumber
        if regions.previewWindows.contains(where: { $0 === window }) {
            observedClosingPopovers[identifier] = window
            // Also cover a preview closed before its opening animation ended.
            disableCloseAnimation(for: popover)
        }
        if remainingWindowNumbers.contains(number) { closingPopovers[identifier] = number }
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if let previous = previousAnimations.object(forKey: popover) {
            popover.animates = previous.boolValue
            previousAnimations.removeObject(forKey: popover)
        }
        let identifier = ObjectIdentifier(popover)
        observedClosingPopovers.removeValue(forKey: identifier)
        guard let number = closingPopovers.removeValue(forKey: identifier) else { return }
        remainingWindowNumbers.remove(number)
        if remainingWindowNumbers.isEmpty {
            // Let the outside-click handler finish publishing preview dismissal.
            DispatchQueue.main.async { [weak self] in self?.finishPendingCollapse() }
        }
    }

    private func disableCloseAnimation(for popover: NSPopover) {
        if previousAnimations.object(forKey: popover) == nil {
            previousAnimations.setObject(NSNumber(value: popover.animates), forKey: popover)
        }
        popover.animates = false
    }

    private func finishPendingCollapse() {
        let store = pendingStore
        let force = pendingForceCollapse
        clearPendingCollapse()
        if let store, (force || !store.keepOpen), !store.previewOpen, store.editingNoteID == nil, store.notice == nil {
            store.isExpanded = false
        }
        store?.isClosingPreview = false
    }

    private func cancelPendingCollapse() {
        let store = pendingStore
        clearPendingCollapse()
        store?.isClosingPreview = false
    }

    private func clearPendingCollapse() {
        closeTimeout?.cancel(); closeTimeout = nil
        pendingStore = nil
        pendingWindows.removeAll()
        closingPopovers.removeAll()
        remainingWindowNumbers.removeAll()
        pendingForceCollapse = false
    }

    func stop() {
        cancelPendingCollapse()
        NotificationCenter.default.removeObserver(self, name: NSPopover.willCloseNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSPopover.didShowNotification, object: nil)
        observingPopovers = false
        observedClosingPopovers.removeAll()
        previousAnimations.removeAllObjects()
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver); menuObservers.removeAll()
        trackingMenus = 0
    }
}
