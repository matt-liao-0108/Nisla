import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

/// Fixture-only native views driven by exactly the window's production curves.
@main struct ShelfMotionPreviews {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandRebound-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinStore(storageDirectory: directory,
            preferences: UserDefaults(suiteName: "IslandRebound-" + UUID().uuidString)!, interactive: false)
        store.options.appearance = "black"
        store.options.shelfWidth = 580
        let layout = PanelLayout()
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/MotionPreviews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let count = 96, fps = 30.0
        let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("shelf-rebound.gif") as CFURL,
            UTType.gif.identifier as CFString, count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let openAt = 0.25, closeAt = 1.75
        let expandedHeight = 32 + store.bodyHeight + ShelfGeometry.footerHeight
        for index in 0..<count {
            let seconds = Double(index) / fps
            let width: Double, height: Double
            if seconds < openAt {
                store.isExpanded = false
                width = 390; height = 32
            } else if seconds < closeAt {
                store.isExpanded = true
                let p = IslandMotion.progress((seconds - openAt) / IslandMotion.shelfDuration(opening: true), opening: true)
                width = 390 + 190 * p.width
                height = 32 + (expandedHeight - 32) * p.height
            } else {
                store.isExpanded = false
                let p = IslandMotion.progress((seconds - closeAt) / IslandMotion.shelfDuration(opening: false), opening: false)
                width = 580 - 190 * p.width
                height = expandedHeight + (32 - expandedHeight) * p.height
            }
            let view = ZStack(alignment: .top) {
                Color(red: 0.12, green: 0.16, blue: 0.22)
                ShelfView().environmentObject(store).environmentObject(layout)
                    .frame(width: width, height: height)
            }.frame(width: 640, height: 280)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            CGImageDestinationAddImage(destination, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
            if index == 19 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("rebound-peak.png"))
            }
        }
        precondition(CGImageDestinationFinalize(destination))
        print("PASS: 96 native shelf frames rendered with production rebound/collapse timing and synthetic data")
    }
}
