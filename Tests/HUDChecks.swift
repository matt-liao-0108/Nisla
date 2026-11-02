import SwiftUI
import AppKit

@MainActor final class PanelLayout: ObservableObject {
    @Published var notchWidth: CGFloat = 180
    @Published var headerHeight: CGFloat = 32
    @Published var dock = "top"
    @Published var compactPresentation = CompactPresentation.full
    @Published var anchorHovered = false
    @Published var attachedToMenuBar = true
}

@main struct HUDChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let menuMark = IslandBrand.menuIcon()
        precondition(IslandBrand.displayName == "Nisla" && menuMark.isTemplate && menuMark.size == NSSize(width: 20, height: 20))
        let iconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Support/Nisla.icns")
        precondition(NSImage(contentsOf: iconURL)?.representations.contains(where: { $0.pixelsWide >= 1024 && $0.pixelsHigh >= 1024 }) == true,
            "The branded app icon must be present at full resolution")
        print("PASS: Nisla name, template menu-bar mark and full-resolution app icon")
        func input(_ key: SystemMediaKey, down: Bool = true, option: Bool = false, shift: Bool = false,
                   command: Bool = false, control: Bool = false) -> SystemMediaInput {
            SystemMediaInput.decode(data1: (key.rawValue << 16) | (down ? 0xA00 : 0xB00), subtype: 8,
                option: option, shift: shift, command: command, control: control)!
        }
        precondition(SystemMediaInput.decode(data1: 21 << 16 | 0xA00, subtype: 8, option: false, shift: false, command: false, control: false) == nil)
        precondition(SystemMediaInput.decode(data1: 0xA00, subtype: 7, option: false, shift: false, command: false, control: false) == nil)
        precondition(SystemMediaInput.decode(data1: 0xC00, subtype: 8, option: false, shift: false, command: false, control: false) == nil)

        var calls = 0, audio = 0.5, brightness = 0.5, muted = false, supported = true
        var lastStep = 0.0
        let router = SystemHUDRouter { key, step in
            guard supported else { return nil }
            calls += 1; lastStep = step
            switch key {
            case .volumeUp: audio = min(1, audio + step)
            case .volumeDown: audio = max(0, audio - step)
            case .mute: muted.toggle()
            case .brightnessUp: brightness = min(1, brightness + step)
            case .brightnessDown: brightness = max(0, brightness - step)
            }
            return SystemHUDReading(kind: key.kind, value: key.kind == .volume ? (muted ? 0 : audio) : brightness, muted: muted)
        }
        precondition(!router.handle(input(.volumeUp)).consumed && calls == 0)
        router.volumeEnabled = true
        let first = router.handle(input(.volumeUp))
        precondition(first.consumed && first.reading?.percentage == 56 && calls == 1)
        precondition(router.handle(input(.volumeUp, down: false)).consumed && calls == 1)
        precondition(!router.handle(input(.volumeUp, down: false)).consumed)
        for _ in 0..<4 { precondition(router.handle(input(.volumeUp)).consumed) }
        precondition(audio == 0.8125)
        _ = router.handle(input(.volumeUp, down: false))
        precondition(!router.handle(input(.volumeUp, option: true)).consumed)
        precondition(!router.handle(input(.volumeUp, command: true)).consumed)
        precondition(!router.handle(input(.volumeUp, control: true)).consumed)
        _ = router.handle(input(.volumeUp))
        precondition(!router.handle(input(.volumeUp, option: true)).consumed)
        precondition(!router.handle(input(.volumeUp, down: false, option: true)).consumed)
        let fine = router.handle(input(.volumeDown, option: true, shift: true))
        precondition(fine.consumed && lastStep == 1.0 / 64)
        precondition(!router.handle(input(.brightnessUp)).consumed)
        router.brightnessEnabled = true
        precondition(router.handle(input(.brightnessUp)).reading?.kind == .brightness)
        let beforeMute = calls
        precondition(router.handle(input(.mute)).reading?.muted == true)
        for _ in 0..<10 { precondition(router.handle(input(.mute)).consumed) }
        precondition(calls == beforeMute + 1 && muted)
        _ = router.handle(input(.mute, down: false))
        precondition(router.handle(input(.mute)).reading?.muted == false)
        router.reset()
        supported = false
        precondition(!router.handle(input(.brightnessDown)).consumed)
        precondition(!router.handle(input(.brightnessDown, down: false)).consumed)
        print("PASS: media-only decode, defaults off, matching releases, repeats, mute hold, fine stepping, shortcuts and failure passthrough")

        let invalid = SystemHUDRouter { _, _ in SystemHUDReading(kind: .volume, value: .nan) }
        invalid.volumeEnabled = true
        precondition(!invalid.handle(input(.volumeUp)).consumed)
        let options = IslandOptions()
        precondition(!(options.hudVolumeEnabled ?? false) && !(options.hudBrightnessEnabled ?? false))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
        legacy.removeValue(forKey: "hudVolumeEnabled"); legacy.removeValue(forKey: "hudBrightnessEnabled")
        let decoded = try JSONDecoder().decode(IslandOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!(decoded.hudVolumeEnabled ?? false) && !(decoded.hudBrightnessEnabled ?? false))
        print("PASS: non-finite readings pass through; existing preferences migrate without enabling capture")

        let denied = SystemHUD(adjust: { _, _ in preconditionFailure("denied permissions must not adjust hardware") }, isTrusted: { false })
        denied.configure(volume: true, brightness: true)
        precondition(!denied.authorized && denied.reading == nil && denied.status.contains("授权"))
        denied.stop()
        print("PASS: denied accessibility is fail-open and does not prompt or install a capture tap")

        // This instance never configures a tap or invokes any hardware backend.
        let hud = SystemHUD(adjust: { _, _ in preconditionFailure("presentation tests must not touch hardware") })
        hud.present(SystemHUDReading(kind: .volume, value: 0.5), duration: .milliseconds(25))
        try await Task.sleep(for: .milliseconds(10))
        hud.present(SystemHUDReading(kind: .brightness, value: 0.7), duration: .milliseconds(500))
        try await Task.sleep(for: .milliseconds(40))
        precondition(hud.reading?.kind == .brightness)
        try await Task.sleep(for: .milliseconds(600))
        precondition(hud.reading == nil)
        precondition(hud.displayReading?.kind == .brightness, "Keep the last content mounted during native retraction")
        try await Task.sleep(for: .milliseconds(350))
        precondition(hud.displayReading == nil)
        hud.present(SystemHUDReading(kind: .volume, value: 0.3))
        hud.stop()
        precondition(hud.reading == nil && hud.displayReading == nil)
        print("PASS: new adjustments replace old dismissal timers; expiry/stop clears only temporary HUD state")

        var directWrites: [(SystemHUDKind, Double)] = []
        var directSupported = true
        let directHUD = SystemHUD(adjust: { _, _ in nil }, setValue: { kind, value in
            directWrites.append((kind, value))
            return directSupported ? SystemHUDReading(kind: kind, value: value, muted: kind == .volume && value == 0) : nil
        })
        directHUD.present(.init(kind: .volume, value: 0.5), duration: .milliseconds(25))
        directHUD.beginSliderInteraction(for: .volume)
        directHUD.setSliderValue(0.75, for: .volume)
        try await Task.sleep(for: .milliseconds(40))
        precondition(directHUD.reading?.percentage == 75, "Dragging must keep the HUD visible")
        directHUD.setSliderValue(-1, for: .volume)
        precondition(directHUD.reading?.percentage == 0 && directHUD.reading?.muted == true)
        precondition(directWrites.last?.1 == 0, "Slider must clamp before touching hardware")
        directHUD.setSliderValue(1, for: .brightness)
        precondition(directWrites.count == 2, "The other control must not be changed")
        directSupported = false
        directHUD.setSliderValue(0.9, for: .volume)
        precondition(directHUD.reading?.percentage == 0, "Failed hardware writes must not fake a value")
        directHUD.endSliderInteraction()
        try await Task.sleep(for: .milliseconds(1500))
        precondition(directHUD.reading == nil, "The HUD must retract after release")
        directHUD.stop()
        print("PASS: slider adjusts only the active control, clamps values, survives dragging and retracts after release")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandHUDChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "IslandHUDChecks-" + UUID().uuidString)!
        let store = PinStore(storageDirectory: directory, preferences: defaults, interactive: false)
        store.options.appearance = "black"
        store.options.presentationStyle = "notch"
        let layout = PanelLayout()
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/HUDPreviews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, reading) in [("volume", SystemHUDReading(kind: .volume, value: 0.56)),
                                ("brightness", SystemHUDReading(kind: .brightness, value: 0.72)),
                                ("muted", SystemHUDReading(kind: .volume, value: 0, muted: true))] {
            SystemHUD.shared.present(reading)
            for notch in [180, 0] {
                let size = SystemHUDGeometry.size(notchWidth: CGFloat(notch), headerHeight: 32)
                let width = Int(size.width), height = Int(size.height)
                precondition(width >= 340 && height == 76)
                layout.notchWidth = CGFloat(notch)
                let view = ShelfView().environmentObject(store).environmentObject(layout)
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
                window.isOpaque = false; window.backgroundColor = .clear; window.contentView = host
                host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name)-\(width).png"))
                if notch > 0 {
                    let scale = CGFloat(bitmap.pixelsWide) / CGFloat(width)
                    for x in stride(from: (width - notch) / 2 + 3, to: (width + notch) / 2 - 3, by: 5) {
                        let color = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(16 * scale))!.usingColorSpace(.sRGB)!
                        precondition(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01)
                    }
                }
            }
        }
        // The temporary HUD hides the regular shelf, so it must cover the
        // hardware-notch header itself even when the chosen material is glass.
        store.options.appearance = "glass"
        SystemHUD.shared.present(.init(kind: .volume, value: 0.56))
        layout.notchWidth = 180
        let glassHUD = NSHostingView(rootView: ShelfView().environmentObject(store).environmentObject(layout)
            .frame(width: 340, height: 76))
        glassHUD.frame = CGRect(x: 0, y: 0, width: 340, height: 76)
        glassHUD.layoutSubtreeIfNeeded()
        let glassBitmap = glassHUD.bitmapImageRepForCachingDisplay(in: glassHUD.bounds)!
        glassHUD.cacheDisplay(in: glassHUD.bounds, to: glassBitmap)
        let glassScale = CGFloat(glassBitmap.pixelsWide) / 340
        for x in stride(from: 18, to: 322, by: 8) {
            let color = glassBitmap.colorAt(x: Int(CGFloat(x) * glassScale), y: Int(8 * glassScale))!.usingColorSpace(.sRGB)!
            precondition(color.redComponent < 0.01 && color.greenComponent < 0.01 && color.blueComponent < 0.01,
                "Glass HUD must hide the physical notch without lighter top wings")
        }
        SystemHUD.shared.stop()
        precondition(!store.isExpanded && store.selectedTab == 0)
        print("PASS: taller standalone HUD renders with/without a physical notch and preserves selected tab/expansion (fixture data only)")
    }
}
