import SwiftUI
import AppKit

enum ShelfMaterialMode: Equatable {
    case black, liquid

    static func resolve(appearance: String, majorVersion: Int, reduceTransparency: Bool) -> Self {
        if reduceTransparency || appearance == "black" { return .black }
        return majorVersion >= 26 ? .liquid : .black
    }

    static func blackCover(reveal: Double) -> Double {
        let progress = min(1, max(0, reveal / 0.55))
        return 1 - progress * progress * (3 - 2 * progress)
    }
}

/// A black optical veil, not a colored/frosted fill. The background supplies
/// the color; progressively less black reveals it toward the lower edge.
enum ShelfGlassProfile {
    static let veil: [(location: Double, opacity: Double)] = [
        (0, 1), (0.24, 0.95), (0.50, 0.78), (0.70, 0.50), (1, 0.42)
    ]
    static func dimming(reveal: Double) -> [(location: Double, opacity: Double)] {
        let cover = ShelfMaterialMode.blackCover(reveal: reveal)
        return veil.map { ($0.location, cover + (1 - cover) * $0.opacity) }
    }
    /// Applied AFTER native optics, including its bright rim. An inner glass
    /// content fill cannot reliably darken the material's outer optical edge.
    static func coating(reveal: Double, height: CGFloat, capsule: Bool) -> [(location: Double, opacity: Double)] {
        if capsule {
            return [(0, 0.68), (0.35, 0.54), (0.72, 0.54), (1, 0.78)]
        }
        // Suppress only the optical edge. A broad 18 pt ramp reads as an
        // unrelated black band beneath the content on dark desktops.
        let rimStart = max(0.92, 1 - 1.5 / max(1, height))
        var stops = dimming(reveal: reveal).filter { $0.location < rimStart }
        let cover = ShelfMaterialMode.blackCover(reveal: reveal)
        stops.append((rimStart, cover + (1 - cover) * 0.42))
        stops.append((1, cover + (1 - cover) * 0.84))
        return stops
    }
}

/// AppKit owns this optical surface. Unlike a SwiftUI in-window glass effect,
/// it is attached directly to a view in the transparent panel's native tree.
@available(macOS 26.0, *)
private struct ShelfNativeGlass: NSViewRepresentable {
    let reveal: Double
    let capsule: Bool
    let shoulders: Bool
    func makeNSView(context: Context) -> ShelfNativeGlassView {
        let view = ShelfNativeGlassView()
        view.configure(reveal: reveal, capsule: capsule, shoulders: shoulders)
        return view
    }
    func updateNSView(_ view: ShelfNativeGlassView, context: Context) {
        view.configure(reveal: reveal, capsule: capsule, shoulders: shoulders)
    }
}

@available(macOS 26.0, *)
final class ShelfNativeGlassView: NSView {
    let glass = NSGlassEffectView()
    let coating = NSView()
    private let gradient = CAGradientLayer()
    private var reveal = 0.0
    private var capsule = false
    private var shoulders = true
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        install()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        install()
    }
    private func install() {
        glass.style = .clear
        glass.tintColor = nil
        glass.appearance = NSAppearance(named: .darkAqua)
        coating.wantsLayer = true
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        coating.layer?.addSublayer(gradient)
        glass.contentView = NSView()
        addSubview(glass)
        addSubview(coating, positioned: .above, relativeTo: glass)
    }

    func configure(reveal: Double, capsule: Bool, shoulders: Bool = true) {
        self.reveal = reveal; self.capsule = capsule; self.shoulders = shoulders
        needsLayout = true
    }
    override func layout() {
        super.layout()
        // Hide the native upper round corners above the physical screen edge;
        // the final NotchOutline supplies the concave upper shoulders. Keep the
        // native lower optical radius aligned with the actual lower silhouette.
        let progress = min(1, max(0, reveal))
        let radius = capsule ? bounds.height / 2 : shoulders ? 10 : min(bounds.height / 2, 18 + 10 * progress)
        let extensionHeight = !capsule && shoulders ? radius : 0
        let sideInset = !capsule && shoulders ? min(10, bounds.width / 8, bounds.height / 3) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.cornerRadius = radius
        glass.frame = CGRect(x: sideInset, y: -extensionHeight,
            width: max(0, bounds.width - 2 * sideInset), height: bounds.height + extensionHeight)
        coating.frame = bounds
        gradient.frame = coating.bounds
        let stops = ShelfGlassProfile.coating(reveal: reveal, height: bounds.height, capsule: capsule)
        gradient.colors = stops.map { NSColor.black.withAlphaComponent($0.opacity).cgColor }
        gradient.locations = stops.map { NSNumber(value: $0.location) }
        CATransaction.commit()
    }
    // The optical background is decorative, never a calendar/tab click target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Foreground content stays in its original SwiftUI tree (no stateful rehosting).
/// A separate native sibling darkens the composited glass BEFORE text/controls,
/// so bright desktops cannot turn the foot or tab bar into a chrome-white strip.
struct ShelfMaterial<Surface: Shape>: ViewModifier {
    let appearance: String
    let reveal: Double
    let shape: Surface
    var capsule = false
    var shoulders = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var mode: ShelfMaterialMode {
        .resolve(appearance: appearance, majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, reduceTransparency: reduceTransparency)
    }

    func body(content: Content) -> some View {
        Group {
            switch mode {
            case .black:
                content.background(.black)
            case .liquid:
                if #available(macOS 26.0, *) {
                    content
                        .background {
                            if reveal <= 0 { Color.black }
                            else {
                                ShelfNativeGlass(reveal: reveal, capsule: capsule, shoulders: shoulders)
                                    .clipShape(shape).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                } else {
                    content.background(.black)
                }
            }
        }
    }
}
