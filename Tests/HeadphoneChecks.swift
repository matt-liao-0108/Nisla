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

@main struct HeadphoneChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(ConnectedHeadphone.isHeadphone(name: "Pods", deviceClass: 0x0418))
        precondition(ConnectedHeadphone.isHeadphone(name: "AirPods Pro", deviceClass: 0))
        precondition(!ConnectedHeadphone.isHeadphone(name: "Keyboard", deviceClass: 0x0540))
        precondition(!ConnectedHeadphone.isHeadphone(name: "Speaker", deviceClass: 0x0414))
        for value: Any in ["0%", "101%", "-1", "unknown", true, Double.nan, Double.infinity, 23.5] {
            precondition(HeadphoneBattery.percent(value) == nil)
        }
        precondition(HeadphoneBattery.percent("82 %") == 82)
        precondition(HeadphoneBattery.percent(100) == 100)
        precondition(ConnectedHeadphone(id: "custom", name: "吹风机",
            battery: .init(left: 100, right: 100, chargingCase: 33)).symbol == "earbuds")
        precondition(ConnectedHeadphone(id: "named", name: "AirPods Pro").symbol == "airpodspro")
        precondition(NSImage(systemSymbolName: "earbuds", accessibilityDescription: nil) != nil)
        precondition(!HeadphoneBannerGeometry.showsText(expansion: 0.75))
        precondition(HeadphoneBannerGeometry.showsText(expansion: 1))
        let payload: [String: Any] = ["SPBluetoothDataType": [[
            "device_connected": [
                ["Same Name": ["device_address": "AA-BB-CC-DD-EE-01", "device_batteryLevelLeft": "82%", "device_batteryLevelRight": "77%", "device_batteryLevelCase": "100%"]],
                ["Same Name": ["device_address": "AA-BB-CC-DD-EE-02", "device_batteryLevelMain": "25%"]]
            ],
            "device_not_connected": [["Old": ["device_address": "AA-BB-CC-DD-EE-03", "device_batteryLevelMain": "90%"]]]
        ]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let levels = HeadphoneBattery.parse(data, address: "aa:bb:cc:dd:ee:01")!
        precondition(levels.percentage == 77 && levels.chargingCase == 100)
        precondition(HeadphoneBattery.parse(data, address: "aa:bb:cc:dd:ee:02")?.percentage == 25)
        precondition(HeadphoneBattery.parse(data, address: "aa:bb:cc:dd:ee:03") == nil)
        precondition(HeadphoneBattery(chargingCase: 100).percentage == nil)
        precondition(HeadphoneBattery.parse(Data("bad".utf8), address: "x") == nil)
        print("PASS: headset filtering, valid percentages, address matching, connected-only data and honest unknown / per-bud battery")

        let one = ConnectedHeadphone(id: "one", name: "AirPods Pro")
        let two = ConnectedHeadphone(id: "two", name: "Headphones")
        var devices = [one]
        var permission = true
        let connection = HeadphoneConnection(snapshot: { devices }, battery: { _ in
            try? await Task.sleep(for: .milliseconds(25))
            return HeadphoneBattery(main: 82)
        }, permitted: { permission }, authorizationUndetermined: { false })
        connection.reconcile()
        precondition(connection.reading == nil) // Disabled: no hardware queries.
        connection.configure(enabled: true)
        precondition(connection.reading == nil) // Existing connection is the baseline.
        devices.append(two); connection.reconcile()
        precondition(connection.reading?.id == two.id)
        try await Task.sleep(for: .milliseconds(550))
        precondition(connection.reading?.battery.percentage == 82)
        connection.dismiss(); connection.reconcile()
        precondition(connection.reading == nil) // Same live device cannot spam banners.
        devices = []; connection.reconcile()
        devices = [one]; connection.reconcile()
        precondition(connection.reading?.id == one.id)
        permission = false; connection.reconcile()
        precondition(connection.reading == nil && connection.status.contains("授权"))
        permission = true; connection.reconcile()
        precondition(connection.reading == nil) // Authorization recovery is another baseline.
        devices = []; connection.reconcile()
        devices = [two]; connection.reconcile()
        connection.stop()
        try await Task.sleep(for: .milliseconds(550))
        precondition(connection.reading == nil)
        print("PASS: baseline, connect, deduplication, reconnect, disconnect, denied permission, recovery and cancellation; fake backends only")

        var snapshotCalls = 0
        let waiting = HeadphoneConnection(snapshot: { snapshotCalls += 1; return [] },
            permitted: { true }, authorizationUndetermined: { true })
        waiting.configure(enabled: true, allowAuthorizationPrompt: false)
        precondition(snapshotCalls == 0 && waiting.status.contains("等待授权"),
            "A previously enabled option must not access Bluetooth at startup before authorization")
        waiting.configure(enabled: true, allowAuthorizationPrompt: true)
        precondition(snapshotCalls == 1, "Explicitly enabling may start the monitor")
        waiting.stop()

        connection.present(one, duration: .milliseconds(20))
        connection.present(two, duration: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(50))
        precondition(connection.reading?.id == two.id && !connection.compact)
        try await Task.sleep(for: .milliseconds(60))
        precondition(connection.reading?.id == two.id && connection.compact)
        try await Task.sleep(for: .milliseconds(140))
        precondition(connection.reading == nil && !connection.compact)
        var oldOptions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(IslandOptions())) as! [String: Any]
        oldOptions.removeValue(forKey: "headphoneConnectionEnabled")
        let decoded = try JSONDecoder().decode(IslandOptions.self, from: JSONSerialization.data(withJSONObject: oldOptions))
        precondition(decoded.headphoneConnectionEnabled == nil)
        print("PASS: auto dismissal, replacement timer and old preferences defaulting off")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IslandHeadphoneTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = UserDefaults(suiteName: "IslandHeadphoneTests-" + UUID().uuidString)!
        let store = PinStore(storageDirectory: directory, preferences: preferences, interactive: false)
        let layout = PanelLayout()
        store.selectedTab = 2
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/HeadphonePreviews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (label, device) in [
            ("airpods", ConnectedHeadphone(id: "test", name: "Maya’s AirPods Pro", battery: .init(main: 82))),
            ("low-battery", ConnectedHeadphone(id: "test", name: "AirPods Pro", battery: .init(left: 18, right: 23, chargingCase: 80))),
            ("unknown", ConnectedHeadphone(id: "test", name: "Wireless Headphones")),
            ("long-name", ConnectedHeadphone(id: "test", name: "A very long custom name for my wireless headphones", battery: .init(main: 91))),
            ("renamed", ConnectedHeadphone(id: "test", name: "吹风机", battery: .init(left: 100, right: 100, chargingCase: 33)))
        ] {
            for expanded in [false, true] {
                store.isExpanded = expanded
                HeadphoneConnection.shared.present(device)
                for width in [440, 580] {
                    let height = 128
                    let view = ShelfView(animateHeadphoneEntrance: false).environmentObject(store).environmentObject(layout)
                        .frame(width: CGFloat(width), height: CGFloat(height))
                        .padding(.horizontal, 18).padding(.bottom, 8)
                        .background(Color(red: 0.23, green: 0.18, blue: 0.34))
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 36, height: height + 8), styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(label)-\(width).png"))
                    let scale = CGFloat(bitmap.pixelsWide) / CGFloat(width + 36)
                    let center = bitmap.colorAt(x: Int(CGFloat(width / 2 + 18) * scale), y: Int(16 * scale))!.usingColorSpace(.sRGB)!
                    precondition(center.redComponent < 0.01 && center.greenComponent < 0.01 && center.blueComponent < 0.01)
                }
                HeadphoneConnection.shared.dismiss()
                precondition(store.selectedTab == 2 && store.isExpanded == expanded)
            }
        }
        // Freeze several native-window heights, including the bad half-closed
        // state from the report. Text must leave before it can get compressed.
        let renamed = ConnectedHeadphone(id: "custom", name: "吹风机", battery: .init(left: 100, right: 100, chargingCase: 33))
        for height in [32, 56, 80, 112, 128] {
            let banner = HeadphoneNotificationBanner(device: renamed, headerHeight: 32,
                track: nil, remoteArtwork: false, animateEntrance: false)
                .environment(\.colorScheme, .light)
                .frame(width: 440, height: CGFloat(height))
            let host = NSHostingView(rootView: banner)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("transition-\(height).png"))
        }
        let artwork = NSImage(size: NSSize(width: 32, height: 32))
        artwork.lockFocus()
        NSColor(red: 0.29, green: 0.19, blue: 0.62, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        artwork.unlockFocus()
        let track = MusicTrack(player: .apple, title: "Fixture song", artist: "Fixture artist", album: "Fixture album",
            playing: true, duration: 100, position: 20, artworkURL: nil, artwork: artwork.tiffRepresentation)
        for (label, sampleTrack) in [("with-artwork", track as MusicTrack?), ("without-artwork", nil)] {
            let compact = HeadphoneCompactBanner(device: ConnectedHeadphone(id: "test", name: "AirPods Pro", battery: .init(main: 82)),
                headerHeight: 32, track: sampleTrack, remoteArtwork: false)
                .frame(width: 390, height: 32)
                .padding(.horizontal, 18).padding(.bottom, 8)
                .background(Color(red: 0.23, green: 0.18, blue: 0.34))
            let host = NSHostingView(rootView: compact)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 426, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("compact-\(label).png"))
        }
        print("PASS: native previews at both widths, compact with/without album art, black physical-notch header, tab / expansion state preserved")
    }
}
