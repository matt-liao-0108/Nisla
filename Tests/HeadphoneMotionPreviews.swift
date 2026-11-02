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

/// Native views and the production window timing, rendered with fixture data.
@main struct HeadphoneMotionPreviews {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/HeadphonePreviews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let frameCount = 72
        let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("system-motion.gif") as CFURL,
            UTType.gif.identifier as CFString, frameCount, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let device = ConnectedHeadphone(id: "fixture", name: "AirPods Pro", battery: .init(main: 82))
        for index in 0..<frameCount {
            let time = Double(index) / 24
            let width: Double, height: Double
            if time < 0.46 {
                let progress = IslandMotion.headphoneProgress(time / 0.46, opening: true)
                width = 390 + 190 * progress.width; height = 32 + 96 * progress.height
            } else if time < 1.7 {
                width = 580; height = 128
            } else {
                let progress = IslandMotion.headphoneProgress((time - 1.7) / 0.38, opening: false)
                width = 580 - 190 * progress.width; height = 128 - 96 * progress.height
            }
            let view = ZStack(alignment: .top) {
                Color(red: 0.23, green: 0.18, blue: 0.34)
                HeadphoneNotificationBanner(device: device, headerHeight: 32, track: nil,
                    remoteArtwork: false, animateEntrance: false).frame(width: width, height: height)
            }.frame(width: 640, height: 160)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let frame = bitmap.cgImage else { fatalError("Native motion frame unavailable") }
            CGImageDestinationAddImage(destination, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 24]] as CFDictionary)
            if index == 2 {
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("motion-midpoint.png"))
            }
        }
        precondition(CGImageDestinationFinalize(destination))
        print("PASS: 72 native motion frames rendered with production spring timing and fixture data")
    }
}
