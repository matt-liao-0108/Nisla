import SwiftUI
import AppKit

// Test layout only; the production definition lives beside the application entry point.
@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

@main struct ShelfCornerChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandCornerChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = UserDefaults(suiteName: "IslandCornerChecks-" + UUID().uuidString)!
        let store = PinStore(storageDirectory: directory, preferences: preferences, interactive: false)
        let layout = PanelLayout()
        let previewDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ShapePreviews")
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        for reveal: CGFloat in [0, 0.1, 0.5, 1] {
            let path = NotchOutline(reveal: reveal).path(in: CGRect(x: 0, y: 0, width: 390, height: 32 + 154 * reveal))
            precondition(path.contains(CGPoint(x: 195, y: 16)))
            precondition(path.contains(CGPoint(x: 6, y: 0.5)))
            precondition(!path.contains(CGPoint(x: 2, y: 15)))
            precondition(!path.contains(CGPoint(x: 388, y: 15)))
            let floating = NotchOutline(reveal: reveal, shoulders: false, floating: true)
                .path(in: CGRect(x: 0, y: 0, width: 390, height: 32 + 154 * reveal))
            precondition(!floating.contains(CGPoint(x: 6, y: 0.5)), "Detached surface must not flare into a notch shoulder")
            precondition(!floating.contains(CGPoint(x: 384, y: 0.5)))
            precondition(floating.contains(CGPoint(x: 195, y: 1)))
        }
        for appearance in ["black", "automatic", "glass"] {
          let nativeGlass = ShelfMaterialMode.resolve(appearance: appearance,
              majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
              reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) == .liquid
          for expanded in [false, true] {
            store.isExpanded = expanded
            store.options.appearance = appearance
            let width = expanded ? 580 : 390
            let height = expanded ? Int(32 + store.bodyHeight + ShelfGeometry.footerHeight) : 32
            let view = ShelfView().environmentObject(store).environmentObject(layout)
                .frame(width: CGFloat(width), height: CGFloat(height))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Native bitmap unavailable") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let rendered = bitmap.cgImage else { fatalError("Native snapshot unavailable") }
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("shelf-\(expanded).png"))
            if !expanded {
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/IslandCollapsedCornerCheck.png"))
            } else if appearance == "black" {
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/IslandExpandedNavigationCheck.png"))
            }
            do {
                let preview = view.padding(.horizontal, 18).padding(.bottom, 8)
                    .background(Color(red: 0.23, green: 0.18, blue: 0.34))
                let filename = (appearance == "black" ? "" : "\(appearance)-") + (expanded ? "expanded.png" : "collapsed.png")
                try savePreview(preview, width: width + 36, height: height + 8,
                    to: previewDirectory.appendingPathComponent(filename))
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            // Inward upper shoulders and rounded lower corners all remain transparent.
            let alphas = [pixels[3], pixels[(width - 1) * 4 + 3], pixels[((height - 1) * width) * 4 + 3], pixels[(height * width - 1) * 4 + 3]]
            precondition(alphas[2] < 10 && alphas[3] < 10, "Rounded corners filled in: \(alphas)")
            // A single final silhouette mask retains its native antialiasing;
            // stacking the same mask used to square this coverage toward zero.
            precondition(alphas[0] < 16 && alphas[1] < 16, "Upper shoulder cutouts missing: \(alphas)")
            let shoulder = expanded ? 12 : 10
            for column in stride(from: shoulder + 2, to: width - shoulder - 2, by: 10) {
                let offset = column * 4
                precondition(pixels[offset + 3] > 250, "Top edge must cover the physical notch")
                // cacheDisplay cannot reproduce compositor-backed Liquid Glass.
                // Check optical colors in the composed, live GlassBackdropPreview
                // windows, not an offscreen PNG or a window-only screenshot.
                if !nativeGlass || !expanded {
                    precondition(pixels[offset] < 5 && pixels[offset + 1] < 5 && pixels[offset + 2] < 5, "Top edge must blend with the physical notch")
                }
            }
            let flareAlpha = pixels[(shoulder / 2) * 4 + 3]
            let insetAlpha = pixels[((shoulder + 2) * width + shoulder / 2) * 4 + 3]
            precondition(flareAlpha > 200 && insetAlpha < 10, "Shoulder must flare outward at the screen edge")
            if appearance == "black" {
                let offset = ((height - 4) * width + width / 2) * 4
                precondition(pixels[offset] == 0 && pixels[offset + 1] == 0 && pixels[offset + 2] == 0 && pixels[offset + 3] == 255, "Classic mode must be solid black, not gray material")
            }
            if expanded {
                let gap = ((height - Int(ShelfGeometry.footerHeight) + 4) * width + width / 2) * 4 + 3
                precondition(pixels[gap] < 10, "Floating navigation gap must remain transparent")
            }
            print("PASS: \(appearance), \(expanded ? "expanded" : "collapsed") silhouette, top coverage and footer gap: \(alphas)\(nativeGlass ? "; optical colors require live-window verification" : "; black pixels verified")")
          }
        }
    }

    @MainActor private static func savePreview<V: View>(_ view: V, width: Int, height: Int, to destination: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: CGFloat(height)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
    }
}
