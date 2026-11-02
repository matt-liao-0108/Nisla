import Foundation
import AppKit

@main struct MaterialChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        if #available(macOS 26.0, *) {
            let backdrop = ShelfNativeGlassView(frame: CGRect(x: 0, y: 0, width: 580, height: 186))
            backdrop.configure(reveal: 1, capsule: false)
            backdrop.layoutSubtreeIfNeeded()
            precondition(backdrop.glass.style == .clear && backdrop.glass.tintColor == nil)
            precondition(backdrop.glass.contentView != nil)
            precondition(backdrop.glass.cornerRadius == 22 && backdrop.glass.frame.minY == -22)
            precondition(backdrop.glass.frame.minX == 12 && backdrop.glass.frame.width == 556,
                "Optical sides must match NotchOutline, not be clipped off outside its shoulders")
            let veil = backdrop.coating
            precondition(backdrop.subviews.last === veil && veil !== backdrop.glass.contentView,
                "Dimming must be after native optics, not inside the glass contentView")
            let gradient = veil.layer!.sublayers!.compactMap { $0 as? CAGradientLayer }.first!
            precondition(!veil.isFlipped && gradient.startPoint.y == 1 && gradient.endPoint.y == 0,
                "The AppKit veil must run black at the top to translucent at the foot")
            precondition(gradient.locations!.first == 0 && gradient.locations!.last == 1)
            let colors = gradient.colors! as! [CGColor]
            precondition(colors.first!.alpha == 1 && abs(colors.last!.alpha - 0.84) < 0.0001)
            backdrop.configure(reveal: 1, capsule: false, shoulders: false)
            backdrop.layoutSubtreeIfNeeded()
            precondition(backdrop.glass.frame.minX == 0 && backdrop.glass.frame.width == 580)
            precondition(backdrop.glass.frame.minY == 0 && backdrop.glass.frame.height == 186,
                "Floating glass must have its own native top corners, not extend above the panel")
            backdrop.configure(reveal: 1, capsule: true)
            backdrop.frame.size = CGSize(width: 214, height: 36)
            backdrop.layoutSubtreeIfNeeded()
            precondition(backdrop.glass.cornerRadius == 18 && backdrop.glass.frame.minY == 0)
            precondition(backdrop.glass.frame.width == 214)
            precondition(backdrop.hitTest(.zero) == nil, "Backdrop must not intercept panel controls")
        }
        precondition(ShelfMaterialMode.resolve(appearance: "automatic", majorVersion: 26, reduceTransparency: false) == .liquid)
        precondition(ShelfMaterialMode.resolve(appearance: "glass", majorVersion: 14, reduceTransparency: false) == .black)
        for version in [14, 15, 25] {
            precondition(ShelfMaterialMode.resolve(appearance: "automatic", majorVersion: version, reduceTransparency: false) == .black)
        }
        precondition(ShelfMaterialMode.resolve(appearance: "black", majorVersion: 26, reduceTransparency: false) == .black)
        precondition(ShelfMaterialMode.resolve(appearance: "glass", majorVersion: 26, reduceTransparency: true) == .black)
        precondition(ShelfMaterialMode.blackCover(reveal: 0) == 1)
        precondition(ShelfMaterialMode.blackCover(reveal: 1) == 0)
        let veil = ShelfGlassProfile.veil
        precondition(veil.first?.location == 0 && veil.first?.opacity == 1)
        precondition(veil.last?.location == 1 && veil.last!.opacity == 0.38)
        for (upper, lower) in zip(veil, veil.dropFirst()) {
            precondition(upper.location < lower.location && upper.opacity > lower.opacity)
            precondition((0...1).contains(lower.location) && (0...1).contains(lower.opacity))
        }
        precondition(ShelfGlassProfile.dimming(reveal: 0).allSatisfy { $0.opacity == 1 })
        for (base, expanded) in zip(veil, ShelfGlassProfile.dimming(reveal: 1)) {
            precondition(base.location == expanded.location && base.opacity == expanded.opacity)
        }
        // The veil is neutral black, not a fixed gray/blue fill. On a bright
        // backdrop it must preserve far more color at the foot than at the top.
        let upperTransmission = 1 - veil[1].opacity
        let lowerTransmission = 1 - veil.last!.opacity
        precondition(upperTransmission < 0.051 && abs(lowerTransmission - 0.62) < 0.0001)
        precondition(lowerTransmission > upperTransmission * 10)
        for height: CGFloat in [32, 128, 186, 234, 420] {
            let coating = ShelfGlassProfile.coating(reveal: 1, height: height, capsule: false)
            for (a, b) in zip(coating, coating.dropFirst()) { precondition(a.location < b.location) }
            precondition(coating.allSatisfy { $0.opacity >= 0.38 && $0.opacity <= 1 })
            precondition(abs(coating[coating.count - 2].opacity - 0.38) < 0.0001)
            precondition(height * (1 - coating[coating.count - 2].location) <= 1.5001,
                "Rim darkening must stay within 1.5 pt, not create a black band below the content")
            precondition(255 * (1 - coating.last!.opacity) < 42,
                "Even a pure-white native rim must remain dark after the coating")
        }
        let tabCoating = ShelfGlassProfile.coating(reveal: 1, height: 36, capsule: true)
        precondition(tabCoating.count == 4 && tabCoating[1].opacity == 0.54 && tabCoating[2].opacity == 0.54)
        precondition(tabCoating[0].opacity == 0.68 && tabCoating.last!.opacity == 0.78)
        precondition(255 * (1 - tabCoating.last!.opacity) < 57)
        var previous = 1.0
        for index in 0...1000 {
            let value = ShelfMaterialMode.blackCover(reveal: Double(index) / 1000)
            precondition((0...1).contains(value) && value <= previous)
            previous = value
        }
        print("PASS: post-optical white-rim suppression, neutral dark tab glass, floating/attached native radii, non-intercepting controls and accessibility fallback")
    }
}
