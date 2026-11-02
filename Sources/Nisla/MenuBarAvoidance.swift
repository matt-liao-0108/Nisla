import AppKit
import ApplicationServices

enum CompactPresentation: Int {
    case notch, icons, full
    var extraWidth: CGFloat { switch self { case .notch: 0; case .icons: 112; case .full: 210 } }
}

struct MenuBarOccupancy: Sendable {
    /// AppKit global coordinates. nil means geometry could not be read reliably.
    var items: [CGRect]?
    var menuBar: CGRect?
}

enum MenuBarAvoidance {
    static let clearance: CGFloat = 12

    static func presentation(notch: CGRect, screen: CGRect, occupancy: MenuBarOccupancy) -> CompactPresentation {
        guard notch.width > 0 else { return .full }
        let band = CGRect(x: screen.minX, y: notch.minY, width: screen.width, height: notch.height)
        // Unknown is not an obstacle. Missing AX permission, a timeout or a
        // reading for another display must not permanently hide both wings.
        // Only geometry belonging to this menu-bar band can trigger avoidance.
        let items = occupancy.menuBar?.intersects(band) == true ? occupancy.items ?? [] : []
        for mode in [CompactPresentation.full, .icons] {
            let candidate = CGRect(x: notch.midX - (notch.width + mode.extraWidth) / 2,
                y: notch.minY, width: notch.width + mode.extraWidth, height: notch.height)
            guard candidate.minX >= screen.minX, candidate.maxX <= screen.maxX else { continue }
            if !items.contains(where: { $0.insetBy(dx: -clearance, dy: 0).intersects(candidate) }) { return mode }
        }
        return .notch
    }

    static func appKitRect(position: CGPoint, size: CGSize, primaryTop: CGFloat) -> CGRect {
        CGRect(x: position.x, y: primaryTop - position.y - size.height, width: size.width, height: size.height)
    }

    static func topFrame(center: CGFloat, screenTop: CGFloat, size: CGSize) -> CGRect {
        CGRect(x: center - size.width / 2, y: screenTop - size.height,
               width: size.width, height: size.height)
    }

    /// The upper edge stays attached to the screen throughout expansion and
    /// collapse. Avoidance changes compact wing width, never the vertical anchor.
    static func frame(from start: CGRect, to target: CGRect,
                      progress: Double, opening: Bool, resizingContent: Bool, headphone: Bool,
                      compactOnly: Bool = false, hud: Bool = false) -> CGRect {
        let t = min(1, max(0, progress))
        if t == 0 { return start }; if t == 1 { return target }
        let m = hud ? IslandMotion.hudProgress(t, opening: opening)
            : resizingContent || compactOnly ? (width: IslandMotion.spring(t), height: IslandMotion.spring(t))
            : headphone ? IslandMotion.headphoneProgress(t, opening: opening)
            : IslandMotion.progress(t, opening: opening)
        let w = start.width + (target.width - start.width) * m.width
        let h = start.height + (target.height - start.height) * m.height
        return CGRect(x: target.midX - w / 2, y: target.maxY - h, width: w, height: h)
    }
}

/// Only reads existing Accessibility geometry. Never prompts, reads menu text,
/// captures screen pixels, or writes to another application's AX elements.
enum MenuBarGeometryReader {
    static func read(pids: [pid_t], frontmost: pid_t?, primaryTop: CGFloat,
                     trusted: Bool) -> MenuBarOccupancy {
        let unknown = MenuBarOccupancy(items: nil, menuBar: nil)
        guard trusted, let frontmost, pids.count <= 96 else { return unknown }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        func attribute(_ element: AXUIElement, _ name: CFString) -> (AXError, CFTypeRef?) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name, &value)
            return (error, value)
        }
        func rect(_ element: AXUIElement) -> CGRect? {
            guard let p = attribute(element, kAXPositionAttribute as CFString).1,
                  let s = attribute(element, kAXSizeAttribute as CFString).1,
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            return MenuBarAvoidance.appKitRect(position: point, size: size, primaryTop: primaryTop)
        }
        func children(_ element: AXUIElement) -> [AXUIElement]? {
            let (error, result) = attribute(element, kAXChildrenAttribute as CFString)
            guard error == .success else { return nil }
            return result as? [AXUIElement]
        }
        let active = AXUIElementCreateApplication(frontmost)
        AXUIElementSetMessagingTimeout(active, 0.025)
        guard let bar = attribute(active, kAXMenuBarAttribute as CFString).1,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return unknown }
        let menuBar = bar as! AXUIElement
        guard let menuFrame = rect(menuBar), let menus = children(menuBar), !menus.isEmpty, menus.count <= 64 else { return unknown }
        var items: [CGRect] = []
        for menu in menus {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return unknown }
            guard let frame = rect(menu) else { return unknown }
            items.append(frame)
        }
        for pid in pids {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return unknown }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.025)
            let (error, extras) = attribute(app, kAXExtrasMenuBarAttribute as CFString)
            if error == .attributeUnsupported || error == .noValue { continue }
            guard error == .success, let extras, CFGetTypeID(extras) == AXUIElementGetTypeID(),
                  let children = children(extras as! AXUIElement), children.count <= 128 else { return unknown }
            for item in children {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return unknown }
                guard let frame = rect(item) else { return unknown }
                items.append(frame)
            }
        }
        return MenuBarOccupancy(items: items, menuBar: menuFrame)
    }
}

@MainActor final class MenuBarMonitor {
    private var task: Task<Void, Never>?
    private var revision = 0
    func invalidate() { revision &+= 1 }
    func start(deliver: @escaping @MainActor (MenuBarOccupancy) -> Void) {
        stop()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let scanRevision = self?.revision else { break }
                let trusted = AXIsProcessTrusted()
                // Never send AX messages at all without an existing grant.
                let pids = trusted ? NSWorkspace.shared.runningApplications.filter {
                    !$0.isTerminated && ($0.activationPolicy != .prohibited ||
                        ["com.apple.systemuiserver", "com.apple.controlcenter"].contains($0.bundleIdentifier ?? ""))
                }.map(\.processIdentifier) : []
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let reading = await Task.detached(priority: .utility) {
                    MenuBarGeometryReader.read(pids: pids, frontmost: frontmost, primaryTop: top, trusted: trusted)
                }.value
                guard !Task.isCancelled else { break }
                deliver(self?.revision == scanRevision && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost
                    ? reading : MenuBarOccupancy(items: nil, menuBar: nil))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
