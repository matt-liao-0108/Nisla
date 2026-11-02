import AppKit

@main struct MenuBarAvoidanceChecks {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: 630, y: 868, width: 180, height: 32)
        let menu = CGRect(x: 0, y: 868, width: 1440, height: 32)
        func mode(_ items: [CGRect]?, bar: CGRect? = nil) -> CompactPresentation {
            MenuBarAvoidance.presentation(notch: notch, screen: screen,
                occupancy: MenuBarOccupancy(items: items, menuBar: bar ?? menu))
        }
        precondition(mode(nil) == .full, "Unknown geometry is not a confirmed collision")
        precondition(mode([]) == .full)
        precondition(MenuBarAvoidance.presentation(notch: notch, screen: screen,
            occupancy: MenuBarOccupancy(items: nil, menuBar: nil)) == .full)
        precondition(mode([CGRect(x: 0, y: 870, width: 460, height: 24),
                           CGRect(x: 1200, y: 870, width: 200, height: 24)]) == .full)
        precondition(mode([CGRect(x: 910, y: 870, width: 24, height: 24)]) == .icons)
        precondition(mode([CGRect(x: 870, y: 870, width: 24, height: 24)]) == .notch)
        precondition(mode([CGRect(x: 0, y: 870, width: 550, height: 24)]) == .icons)
        precondition(mode([CGRect(x: 0, y: 870, width: 570, height: 24)]) == .notch)
        precondition(mode([CGRect(x: 910, y: 500, width: 24, height: 24)]) == .full)
        precondition(mode([CGRect(x: 870, y: 870, width: 24, height: 24)],
            bar: menu.offsetBy(dx: 1500, dy: 0)) == .full, "Other display's reading must not shrink this notch")
        precondition(MenuBarAvoidance.presentation(notch: .zero, screen: screen,
            occupancy: MenuBarOccupancy(items: [], menuBar: menu)) == .full)
        // Normal width returns on the very next clear or unavailable reading,
        // rather than latching a previous collision / app-switch fallback.
        let blocked = [CGRect(x: 870, y: 870, width: 24, height: 24)]
        for (reading, expected) in [(blocked as [CGRect]?, CompactPresentation.notch),
                                    (nil, .full), (blocked, .notch), ([], .full)] {
            precondition(mode(reading) == expected)
        }
        let narrowScreen = CGRect(x: 610, y: 0, width: 220, height: 900)
        precondition(MenuBarAvoidance.presentation(notch: notch, screen: narrowScreen,
            occupancy: MenuBarOccupancy(items: nil, menuBar: nil)) == .notch,
            "Even the unknown fallback must remain inside the display")
        let secondary = screen.offsetBy(dx: -1440, dy: 200)
        precondition(MenuBarAvoidance.presentation(notch: notch.offsetBy(dx: -1440, dy: 200), screen: secondary,
            occupancy: MenuBarOccupancy(items: [CGRect(x: -570, y: 1070, width: 24, height: 24)],
                menuBar: menu.offsetBy(dx: -1440, dy: 200))) == .notch)
        precondition(MenuBarAvoidance.appKitRect(position: CGPoint(x: -500, y: -200),
            size: CGSize(width: 24, height: 32), primaryTop: 900) == CGRect(x: -500, y: 1068, width: 24, height: 32))
        let denied = MenuBarGeometryReader.read(pids: [12345], frontmost: 12345, primaryTop: 900, trusted: false)
        precondition(denied.items == nil && denied.menuBar == nil)
        precondition(MenuBarAvoidance.presentation(notch: notch, screen: screen, occupancy: denied) == .full)
        print("PASS: confirmed collisions only, unknown/denied AX normal width, immediate recovery, screen bounds and multi-display coordinates")

        let compact = MenuBarAvoidance.topFrame(center: 720, screenTop: 900, size: CGSize(width: 390, height: 32))
        let expanded = MenuBarAvoidance.topFrame(center: 720, screenTop: 900, size: CGSize(width: 580, height: 234))
        let notchOnly = MenuBarAvoidance.topFrame(center: 720, screenTop: 900, size: CGSize(width: 180, height: 32))
        let notchless = MenuBarAvoidance.topFrame(center: 720, screenTop: 900, size: CGSize(width: 270, height: 32))
        precondition(notchless.maxY == 900 && expanded.maxY == 900 && compact.maxY == 900)
        for (start, target) in [(compact, expanded), (expanded, compact), (notchOnly, expanded), (expanded, notchOnly)] {
            for headphone in [false, true] {
                for step in 0...1000 {
                    let t = Double(step) / 1000
                    let frame = MenuBarAvoidance.frame(from: start, to: target,
                        progress: t, opening: target.height > start.height, resizingContent: false, headphone: headphone)
                    precondition(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0)
                    precondition(abs(frame.maxY - 900) < 0.001, "Expansion must never detach from the top edge")
                    if step == 0 { precondition(frame == start) }
                    if step == 1000 { precondition(frame == target) }
                }
            }
        }
        for step in 0...1000 {
            let f = MenuBarAvoidance.frame(from: notchOnly, to: compact,
                progress: Double(step) / 1000, opening: true, resizingContent: false, headphone: false, compactOnly: true)
            precondition(f.width <= compact.width + 0.001, "Compact width must not bounce into an adjacent icon")
        }
        // Rapid reversals retain the same top anchor too.
        for step in stride(from: 1, to: 1000, by: 19) {
            let interrupted = MenuBarAvoidance.frame(from: compact, to: expanded,
                progress: Double(step) / 1000, opening: true, resizingContent: false, headphone: false)
            for next in stride(from: 0, through: 1000, by: 11) {
                let f = MenuBarAvoidance.frame(from: interrupted, to: compact,
                    progress: Double(next) / 1000, opening: false, resizingContent: false, headphone: false)
                precondition(abs(f.maxY - 900) < 0.001)
            }
        }
        print("PASS: expansion, collapse and toasts stay attached to the top across 8,000 motion samples and rapid reversals; compact wings do not overshoot")
        let hud = MenuBarAvoidance.topFrame(center: 720, screenTop: 900, size: CGSize(width: 420, height: 76))
        for (start, target) in [(compact, hud), (hud, compact), (expanded, hud), (hud, expanded)] {
            for step in 0...1000 {
                let f = MenuBarAvoidance.frame(from: start, to: target, progress: Double(step) / 1000,
                    opening: target.height > start.height, resizingContent: false, headphone: false, hud: true)
                precondition(abs(f.maxY - 900) < 0.001 && f.height >= 32)
            }
        }
        print("PASS: volume/brightness HUD growth, retraction and expanded-page restoration stay top-anchored")
    }
}
