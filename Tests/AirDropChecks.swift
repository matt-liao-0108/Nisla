import AppKit
import UniformTypeIdentifiers

@main struct AirDropChecks {
    @MainActor static func main() async {
        func routed(_ point: CGPoint, expanded: Bool = true, hasFiles: Bool = true) -> Bool {
            AirDropDropRouting.contains(point, panelWidth: 580, headerHeight: 32,
                bodyHeight: 154, expanded: expanded, hasFiles: hasFiles)
        }
        precondition(routed(CGPoint(x: 490, y: 90)))
        precondition(!routed(CGPoint(x: 300, y: 90)))
        precondition(!routed(CGPoint(x: 490, y: 20)))
        precondition(!routed(CGPoint(x: 490, y: 200)))
        precondition(!routed(CGPoint(x: 490, y: 90), expanded: false))
        precondition(!routed(CGPoint(x: 490, y: 90), hasFiles: false))
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 948),
                       CGRect(x: 1512, y: 0, width: 1200, height: 650)] {
            let host = AirDropPresentation.hostFrame(in: screen)
            precondition(screen.contains(host), "The AirDrop sheet anchor must fit on the selected screen")
            precondition(abs(host.midX - screen.midX) < 0.5)
            precondition(host.maxY < screen.maxY - 70, "The sheet must not anchor to the menu bar")
            let alert = AirDropPresentation.centeredAlertFrame(size: CGSize(width: 500, height: 280), in: screen)
            precondition(screen.contains(alert))
            precondition(abs(alert.midX - screen.midX) < 0.5 && abs(alert.midY - screen.midY) < 0.5,
                         "AirDrop errors must be centered on the current display")
        }

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-airdrop-\(UUID().uuidString).pdf")
        try! Data("%PDF-1.4\n%%EOF".utf8).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let file = NSItemProvider(object: fixtureURL as NSURL)
        // The headless test sandbox has no Launch Services type registry;
        // register the generic image type directly instead of relying on PNG
        // conformance being available in that environment.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let image = NSItemProvider(item: bitmap.representation(using: .png, properties: [:])! as NSData, typeIdentifier: UTType.image.identifier)
        let text = NSItemProvider(object: "fixture text" as NSString)
        let mixed = NSItemProvider()
        mixed.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { handler in
            handler(Data("not a file URL".utf8), nil)
            return nil
        }
        let png = bitmap.representation(using: .png, properties: [:])!
        // The headless test environment lacks the PNG -> image conformance
        // registry, so advertise the generic image type directly.
        mixed.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier, visibility: .all) { handler in
            handler(png, nil)
            return nil
        }
        var recovered: DragItemReader.Value?
        DragItemReader.load(mixed, filesAndImagesOnly: true) { recovered = $0 }
        for _ in 0..<200 where recovered == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard case .image = recovered else { preconditionFailure("A failed file URL must fall back to the concrete image representation") }
        recovered = nil
        DragItemReader.load(text) { recovered = $0 }
        for _ in 0..<200 where recovered == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard case .text("fixture text") = recovered else { preconditionFailure("Plain text must remain importable") }
        precondition(AirDropSharing.supports(file) && AirDropSharing.supports(image))
        precondition(!AirDropSharing.supports(text))
        var error: String?
        precondition(!AirDropSharing.shared.share([file, text]) { error = $0 })
        precondition(error != nil, "A mixed unsupported batch must be rejected without opening a share service")
        error = nil
        precondition(!AirDropSharing.shared.share([]) { error = $0 } && error != nil)
        error = nil
        var launches = 0
        let fixtureService = NSSharingService(title: "Fixture", image: NSImage(size: NSSize(width: 16, height: 16)), alternateImage: nil) { launches += 1 }
        var presentations = 0
        var pickerVisible = true
        let controller = AirDropSharing(makeService: { fixtureService }, present: { action in
            presentations += 1
            action()
        }, presentationVisible: { pickerVisible })
        precondition(controller.responds(to: NSSelectorFromString("sharingService:sourceWindowForShareItems:sharingContentScope:")),
                     "The source-window hook must be visible to AppKit")
        precondition(controller.share([file, image]) { error = $0 })
        precondition(launches == 0, "Providers must be resolved before presentation")
        for _ in 0..<200 where launches == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(launches == 1 && error == nil, "Resolution failed: \(error ?? "no callback")")
        error = nil
        precondition(!controller.share([file]) { error = $0 } && error != nil, "A second share cannot replace an active session")
        controller.sharingWindowDidEnd(fixtureService)
        error = nil
        precondition(controller.share([file, image]) { error = $0 })
        for _ in 0..<200 where launches == 1 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(launches == 2 && error == nil,
            "Closing the picker without a delegate callback must release the next batch")
        precondition(presentations == 2, "Every accepted share must go through the presentation step")
        controller.sharingService(fixtureService, didFailToShareItems: [],
            error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        error = nil
        precondition(controller.share([image]) { error = $0 })
        for _ in 0..<200 where launches == 2 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(launches == 3 && error == nil, "Explicit cancellation must also release the next batch")
        pickerVisible = false
        precondition(controller.share([image]) { error = $0 },
                     "A closed standalone picker with no callbacks must not block the next drop")
        pickerVisible = true
        for _ in 0..<200 where launches == 3 { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(launches == 4 && error == nil)
        controller.sharingService(fixtureService, didShareItems: [])
        let broken = NSItemProvider(item: Data([0]) as NSData, typeIdentifier: UTType.image.identifier)
        precondition(controller.share([broken]) { error = $0 })
        for _ in 0..<200 where error == nil { try? await Task.sleep(for: .milliseconds(10)) }
        precondition(error != nil && launches == 4, "Unreadable images must report an error, not silently launch")
        print("PASS: AirDrop hit testing, mixed-batch rejection, multi-item dispatch, busy-session protection and cancellation recovery; fake service only")
    }
}
