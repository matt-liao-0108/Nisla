import AppKit
import SwiftUI
import Combine

/// Exercises the real native panel, with fixture storage and direct HUD
/// presentation only. No media-key interception, audio writes or permissions.
@main struct PanelFrameChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            print("SKIP: native panel checks require a WindowServer display; pure geometry and render suites still run")
            exit(77)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandPanelChecks-" + UUID().uuidString)
        let store = PinStore(storageDirectory: directory,
            preferences: UserDefaults(suiteName: "IslandPanelChecks-" + UUID().uuidString)!, interactive: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.options.appearance = "black"; store.selectedTab = 1; store.keepOpen = true
        store.options.presentationStyle = "notch"
        let panel = IslandPanel(store: store, screen: screen)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); SystemHUD.shared.stop() }
        let header = max(32, screen.safeAreaInsets.top)
        let notch = screen.auxiliaryTopLeftArea.flatMap { left in screen.auxiliaryTopRightArea.map { max(0, $0.minX - left.maxX) } } ?? 0
        let hudSize = SystemHUDGeometry.size(notchWidth: notch, headerHeight: header)

        func sample(_ duration: Double) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < duration {
                precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
                precondition(panel.frame.height >= header - 0.5)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        SystemHUD.shared.present(.init(kind: .volume, value: 0.19), duration: .seconds(10))
        panel.setExpanded(false)
        try await sample(0.55)
        precondition(abs(panel.frame.width - hudSize.width) < 0.5 && abs(panel.frame.height - hudSize.height) < 0.5)
        let settled = panel.frame
        for level in [0.25, 0.31, 0.38, 0.44] {
            SystemHUD.shared.present(.init(kind: .volume, value: level), duration: .seconds(10))
            panel.setExpanded(false)
            precondition(panel.frame == settled, "Held volume keys must not restart the entrance")
        }
        SystemHUD.shared.stop(); panel.setExpanded(false)
        try await sample(0.45)
        precondition(abs(panel.frame.height - header) < 0.5)
        precondition(store.selectedTab == 1 && !store.isExpanded)

        store.isExpanded = true; panel.setExpanded(true)
        try await sample(0.95)
        let page = panel.frame
        store.isResizingWidth = true
        for width in [600.0, 740, 520, 580] {
            panel.setExpanded(true, shelfWidth: width)
            precondition(abs(panel.frame.width - width) < 0.5, "Interactive resize must apply synchronously, without debounce or animation")
            precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
        }
        store.isResizingWidth = false
        panel.setExpanded(true)
        try await sample(0.95)
        precondition(panel.frame == page)
        SystemHUD.shared.present(.init(kind: .brightness, value: 0.72), duration: .seconds(10))
        panel.setExpanded(true)
        try await sample(0.55)
        precondition(abs(panel.frame.height - hudSize.height) < 0.5)
        SystemHUD.shared.stop(); panel.setExpanded(true)
        try await sample(0.55)
        precondition(panel.frame == page && store.selectedTab == 1 && store.isExpanded)

        // The responder path must collapse native geometry even while a
        // detached preview is being dismissed, not only change SwiftUI state.
        let preview = NSPopover()
        let previewController = NSViewController()
        previewController.view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        preview.contentViewController = previewController
        preview.behavior = .transient
        preview.show(relativeTo: NSRect(x: 80, y: 80, width: 30, height: 24), of: panel.contentView!, preferredEdge: .minY)
        store.previewOpen = true
        panel.cancelOperation(nil)
        preview.close()
        try await sample(0.80)
        precondition(!store.isExpanded && !store.previewOpen)
        precondition(abs(panel.frame.height - header) < 0.5)

        // Simulate source-window displacement after a completed animation.
        // Freeze native correction briefly so the same-target cache path is
        // exercised, then confirm the cached destination repairs the real frame.
        // Hide the fixture during deliberate displacement so users do not see
        // a fabricated mid-screen island while these checks run.
        panel.orderOut(nil)
        store.isResizingWidth = true
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 70, y: screen.frame.midY))
        precondition(abs(panel.frame.maxY - screen.frame.maxY) > 10)
        store.isResizingWidth = false
        panel.setExpanded(false)
        precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
        precondition(abs(panel.frame.midX - (screen.auxiliaryTopLeftArea.map { $0.maxX + notch / 2 } ?? screen.frame.midX)) < 0.5)
        // A later AppKit move is corrected without waiting for a state change.
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: screen.frame.midY))
        try await Task.sleep(for: .milliseconds(30))
        precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
        panel.orderFrontRegardless()

        for _ in 0..<2 {
            store.isExpanded = true; panel.setExpanded(true)
            try await sample(0.10)
            panel.cancelOperation(nil)
            try await sample(0.10)
        }
        try await sample(0.80)
        precondition(abs(panel.frame.height - header) < 0.5 && !store.isExpanded)
        print("PASS: Escape with native popover, completed-animation frame drift, same-target repair and rapid reversal retain the attached anchor")
        print("PASS: real native HUD panel grows and retracts at the top, held updates do not restart motion, original expanded page restores; fixture data only")
        store.options.presentationStyle = "floating"
        panel.setExpanded(false)
        try await Task.sleep(for: .seconds(1))
        let floatingTop = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - FloatingIslandGeometry.topGap
        precondition(abs(panel.frame.maxY - floatingTop) < 0.5)
        precondition(abs(panel.frame.height - 36) < 0.5 && abs(panel.frame.width - 200) < 0.5)
        store.isExpanded = true; panel.setExpanded(true)
        try await Task.sleep(for: .seconds(1))
        precondition(abs(panel.frame.maxY - floatingTop) < 0.5)
        precondition(abs(panel.frame.height - (36 + ShelfGeometry.bodyHeight(store.bodyHeight, floating: true, selectedTab: store.selectedTab) + ShelfGeometry.footerHeight)) < 0.5)
        SystemHUD.shared.present(.init(kind: .volume, value: 0.51), duration: .seconds(10))
        panel.setExpanded(true)
        try await Task.sleep(for: .milliseconds(600))
        precondition(abs(panel.frame.maxY - floatingTop) < 0.5)
        precondition(abs(panel.frame.height - 44) < 0.5, "Floating HUD must not reserve an empty physical-notch header")
        panel.cancelOperation(nil)
        try await Task.sleep(for: .seconds(1))
        precondition(SystemHUD.shared.reading == nil, "Escape dismisses the toast without disabling future system key capture")
        precondition(abs(panel.frame.maxY - floatingTop) < 0.5 && abs(panel.frame.height - 36) < 0.5)
        panel.orderOut(nil)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: screen.frame.midY))
        try await Task.sleep(for: .milliseconds(30))
        precondition(abs(panel.frame.maxY - floatingTop) < 0.5, "Escape/drift repair must restore floating anchor, not force the old screen edge")
        panel.orderFrontRegardless()
        print("PASS: floating capsule opens, collapses with Escape and repairs drift at the top safe-area gap")

        // Exercise an image popover, then model a late AppKit move that arrives
        // while geometry notifications are temporarily suppressed.
        store.isExpanded = true; panel.setExpanded(true)
        try await Task.sleep(for: .seconds(1))
        let imagePreview = NSPopover()
        let imageController = NSViewController()
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 340, height: 220))
        imageView.image = NSImage(size: NSSize(width: 80, height: 80))
        imageController.view = imageView
        imagePreview.contentViewController = imageController
        imagePreview.behavior = .transient
        imagePreview.show(relativeTo: NSRect(x: 80, y: 80, width: 100, height: 80), of: panel.contentView!, preferredEdge: .minY)
        store.previewOpen = true
        try await Task.sleep(for: .milliseconds(150))
        imagePreview.close(); store.previewOpen = false
        store.isExpanded = false; panel.setExpanded(false)
        try await Task.sleep(for: .seconds(1))
        panel.orderOut(nil)
        store.isResizingWidth = true
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 60, y: screen.frame.midY))
        store.isResizingWidth = false
        try await Task.sleep(for: .milliseconds(350))
        precondition(abs(panel.frame.maxY - floatingTop) < 0.5 && abs(panel.frame.midX - screen.frame.midX) < 0.5,
            "A late move after image preview must recover even without another state update")
        precondition(abs(panel.frame.height - 36) < 0.5)
        panel.orderFrontRegardless()
        print("PASS: image preview close and a late suppressed frame move recover the floating anchor")

        // Mirror the application's deferred publication handling, then deliver
        // real AppKit key events rather than calling cancelOperation directly.
        let updates = store.objectWillChange.sink { [weak panel, weak store] _ in
            DispatchQueue.main.async {
                guard let panel, let store else { return }
                panel.setExpanded(store.isExpanded)
            }
        }
        defer { updates.cancel() }
        // Open the actual SwiftUI image-card popover, not a standalone
        // substitute, then collapse while the popover is being dismissed.
        store.selectedTab = 0
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32)!
        let imageURL = directory.appendingPathComponent("fixture.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let imageItem = PinItem(kind: .image, title: "Fixture", payload: imageURL.path)
        store.items = [imageItem]
        let outsideMonitor = ShelfOutsideClickMonitor()
        outsideMonitor.observePopoverLifecycle()
        defer { outsideMonitor.stop() }
        for style in ["notch", "floating"] {
            store.options.presentationStyle = style
            store.keepOpen = true
            store.isExpanded = true; panel.setExpanded(true)
            panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .init("NislaTestHoverPinPreview"), object: imageItem.id)
            try await Task.sleep(for: .milliseconds(850))
            precondition(store.previewOpen, "The actual image-card preview must open")
            guard let popupWindow = ShelfInteractionRegions.shared.windows.first(where: { $0 !== panel }) else {
                preconditionFailure("The image preview must be presented in its real separate window")
            }
            popupWindow.makeKeyAndOrderFront(nil)
            popupWindow.makeFirstResponder(popupWindow.contentView)
            store.keepOpen = false
            let outsidePoint = NSPoint(x: screen.frame.minX + 2, y: screen.frame.minY + 2)
            let expandedFrame = panel.frame
            outsideMonitor.handle(point: outsidePoint, store: store)
            precondition(store.isExpanded && store.isClosingPreview && !store.previewOpen,
                "The panel must wait for the actual preview close animation")
            outsideMonitor.handle(point: outsidePoint, store: store)
            precondition(store.isExpanded && store.isClosingPreview, "Repeated clicks must not bypass the preview close")
            let top = style == "floating" ? floatingTop : screen.frame.maxY
            let height: CGFloat = style == "floating" ? 36 : header
            let start = ProcessInfo.processInfo.systemUptime
            var displayedWindowSamples = 0
            var collapseStartedAt: Double?
            var maximumSizeDelta: CGFloat = 0
            while ProcessInfo.processInfo.systemUptime - start < 1.8 {
                if !store.isExpanded && collapseStartedAt == nil {
                    collapseStartedAt = ProcessInfo.processInfo.systemUptime - start
                }
                if store.isClosingPreview {
                    precondition(store.isExpanded && abs(panel.frame.width - expandedFrame.width) < 0.5 && abs(panel.frame.height - expandedFrame.height) < 0.5,
                        "The native panel must not shrink while its real preview is closing")
                }
                let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]] ?? []
                if let bounds = windowInfo.first?[kCGWindowBounds as String] as? [String: Any],
                   let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
                   let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber {
                    displayedWindowSamples += 1
                    let displayedCenter = CGFloat(truncating: x) + CGFloat(truncating: width) / 2
                    let displayedTop = CGFloat(truncating: y)
                    let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
                    precondition(abs(displayedCenter - expandedFrame.midX) < 2 &&
                                 abs(displayedTop - (primaryTop - top)) < 2,
                        "The displayed panel must remain centered and anchored to the screen during collapse")
                    maximumSizeDelta = max(maximumSizeDelta, abs(CGFloat(truncating: width) - panel.frame.width),
                                           abs(CGFloat(truncating: height) - panel.frame.height))
                    precondition(abs(CGFloat(truncating: width) - panel.frame.width) < 60 &&
                                 abs(CGFloat(truncating: height) - panel.frame.height) < 60,
                        "The displayed WindowServer size must follow the AppKit panel during collapse")
                }
                precondition(abs(panel.frame.maxY - top) < 0.5,
                    "The actual outside-click path must keep the panel anchored during collapse")
                try await Task.sleep(for: .milliseconds(16))
            }
            print("Preview close to panel collapse (\(style)): \(collapseStartedAt ?? -1) s")
            print("Maximum displayed/AppKit size difference (\(style)): \(maximumSizeDelta) pt")
            precondition(collapseStartedAt.map { $0 < 0.35 } == true,
                "The main panel should begin collapsing promptly after the outside click")
            precondition(displayedWindowSamples > 0, "The actual displayed window must be sampled")
            precondition(!store.isClosingPreview && !store.isExpanded && abs(panel.frame.height - height) < 0.5 && !store.previewOpen,
                "The actual preview completion notification must allow a completed collapse")

            // A transient popover may begin closing before the global mouse
            // monitor receives the outside click. That ordering must wait too.
            store.keepOpen = true
            store.isExpanded = true; panel.setExpanded(true)
            try await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .init("NislaTestHoverPinPreview"), object: imageItem.id)
            try await Task.sleep(for: .milliseconds(850))
            precondition(store.previewOpen)
            store.dismissPreviews()
            try await Task.sleep(for: .milliseconds(100))
            store.keepOpen = false
            outsideMonitor.handle(point: outsidePoint, store: store)
            precondition((store.isExpanded && store.isClosingPreview) || (!store.isExpanded && !store.isClosingPreview),
                "An already-closed preview may collapse immediately; a closing one must defer")
            try await Task.sleep(for: .seconds(1.8))
            precondition(!store.isClosingPreview && !store.isExpanded && abs(panel.frame.maxY - top) < 0.5 && abs(panel.frame.height - height) < 0.5,
                "An already-closing preview must complete before collapse")
        }
        for style in ["notch", "floating"] {
            store.options.presentationStyle = style
            store.keepOpen = true
            store.isExpanded = true; panel.setExpanded(true)
            try await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .init("NislaTestHoverPinPreview"), object: imageItem.id)
            try await Task.sleep(for: .milliseconds(850))
            precondition(store.previewOpen)
            panel.cancelOperation(nil)
            precondition(store.isExpanded && store.isClosingPreview, "Escape must also wait for the preview animation")
            try await Task.sleep(for: .seconds(1.8))
            let top = style == "floating" ? floatingTop : screen.frame.maxY
            let height: CGFloat = style == "floating" ? 36 : header
            precondition(!store.isClosingPreview && !store.isExpanded && abs(panel.frame.maxY - top) < 0.5 && abs(panel.frame.height - height) < 0.5,
                "Escape must finish collapsing even when the shelf was pinned open")
        }
        store.options.presentationStyle = "floating"
        store.keepOpen = true
        panel.setExpanded(false)
        try await Task.sleep(for: .seconds(1))
        // Collapse before the hover delay expires: a stale task must never
        // present a preview on a compact or already-closing panel.
        store.isExpanded = true; panel.setExpanded(true)
        try await Task.sleep(for: .seconds(1))
        NotificationCenter.default.post(name: .init("NislaTestHoverPinPreview"), object: imageItem.id)
        try await Task.sleep(for: .milliseconds(100))
        store.isExpanded = false; panel.setExpanded(false)
        try await Task.sleep(for: .seconds(1))
        precondition(!store.previewOpen && abs(panel.frame.maxY - floatingTop) < 0.5 && abs(panel.frame.height - 36) < 0.5,
            "A pending hover task must not reopen the image preview after collapse")
        precondition(!ShelfInteractionRegions.shared.windows.contains(where: { $0 !== panel }),
            "No detached image preview should remain after a hover is cancelled by collapse")
        print("PASS: actual SwiftUI image preview closes on collapse and pending hover cannot reopen it")
        func escape(in window: NSWindow) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
            window.sendEvent(event)
        }
        func anchored(for duration: Double, at top: CGFloat) async throws {
            let began = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - began < duration {
                precondition(abs(panel.frame.maxY - top) < 0.5, "Every animation frame must retain its screen anchor")
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        for style in ["notch", "floating"] {
            store.options.presentationStyle = style
            store.isExpanded = false
            panel.position()
            try await Task.sleep(for: .seconds(1))
            let top = style == "floating" ? floatingTop : screen.frame.maxY
            let compactHeight = style == "floating" ? 36 : header
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
            for _ in 0..<3 {
                store.isExpanded = true
                panel.setExpanded(true)
                try await anchored(for: 0.08, at: top)
                escape(in: panel)
                escape(in: panel)
                try await anchored(for: 0.8, at: top)
                precondition(!store.isExpanded && abs(panel.frame.height - compactHeight) < 0.5,
                    "Actual Escape events must collapse the shelf, including repeated Escape during opening")
            }

            // A detached text preview may consume the first Escape itself.
            // It must never move its source window away from the top anchor.
            store.isExpanded = true; panel.setExpanded(true)
            try await anchored(for: 0.9, at: top)
            let textPreview = NSPopover()
            let controller = NSViewController()
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
            editor.string = "Fixture note: Escape must not move the source panel."
            controller.view = editor
            textPreview.contentViewController = controller
            textPreview.behavior = .transient
            textPreview.show(relativeTo: NSRect(x: 80, y: 80, width: 30, height: 24),
                of: panel.contentView!, preferredEdge: .minY)
            if let previewWindow = editor.window {
                previewWindow.makeKeyAndOrderFront(nil)
                previewWindow.makeFirstResponder(editor)
                escape(in: previewWindow)
            }
            try await anchored(for: 0.15, at: top)
            textPreview.close()
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
            escape(in: panel)
            try await anchored(for: 0.8, at: top)
            precondition(!store.isExpanded && abs(panel.frame.height - compactHeight) < 0.5)
        }
        print("PASS: actual Escape key events, rapid repeats, opening interruption and focused text popover preserve attached/floating anchors")
        store.options.presentationStyle = nil
        panel.position()
        try await Task.sleep(for: .seconds(1))
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let automaticSupport = NativeIslandCompatibility.current(builtInDisplay: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
        if automaticSupport != .verified {
            precondition(abs(panel.frame.maxY - screen.frame.maxY) < 0.5)
            precondition(abs(panel.frame.height - header) < 0.5, "Automatic must retain the original notch on this unverified/unsupported machine")
            store.isExpanded = true; panel.setExpanded(true)
            try await anchored(for: 0.9, at: screen.frame.maxY)
            escape(in: panel)
            try await anchored(for: 0.8, at: screen.frame.maxY)
            precondition(!store.isExpanded && abs(panel.frame.height - header) < 0.5)
        }
        print("PASS: automatic presentation on the actual system retains the notch and its Escape anchor when native island support is unverified")
    }
}
