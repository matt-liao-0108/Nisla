import SwiftUI
import IOBluetooth
import CoreBluetooth

struct ConnectedHeadphone: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    var battery: HeadphoneBattery = .init()

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        // A custom Bluetooth name is not a model identifier. Per-bud readings
        // let us show generic earbuds without inventing an AirPods model.
        if battery.left != nil || battery.right != nil { return "earbuds" }
        return "headphones"
    }

    static func isHeadphone(name: String, deviceClass: UInt32) -> Bool {
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("耳机") || lower.contains("headphone") || lower.contains("buds") { return true }
        let major = (deviceClass >> 8) & 0x1F
        let minor = (deviceClass >> 2) & 0x3F
        return major == 4 && [1, 2, 6].contains(minor)
    }

    static func address(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "-", with: ":").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct HeadphoneBattery: Equatable, Sendable {
    var main: Int?
    var left: Int?
    var right: Int?
    var chargingCase: Int?
    // The case must never stand in for the listening battery. With two buds,
    // show the lower charge, not an optimistic average.
    var percentage: Int? { [left, right].compactMap { $0 }.min() ?? main }
    var detail: String? {
        let parts = [("左", left), ("右", right), ("盒", chargingCase)]
            .compactMap { label, value in value.map { "\(label) \($0)%" } }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func percent(_ value: Any?) -> Int? {
        let number: Int?
        if let text = value as? String { number = Int(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let raw = value.doubleValue
            number = raw.isFinite && raw.rounded() == raw && (0...100).contains(raw) ? Int(raw) : nil
        } else { number = nil }
        // Bluetooth uses zero for an unavailable cached reading on some devices.
        return number.flatMap { (1...100).contains($0) ? $0 : nil }
    }

    static func parse(_ data: Data, address: String) -> Self? {
        guard data.count <= 12 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for controller in controllers {
            // Ignore disconnected/cached entries and match by address, never name.
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for value in entry.values {
                    guard let info = value as? [String: Any], let raw = info["device_address"] as? String,
                          ConnectedHeadphone.address(raw) == ConnectedHeadphone.address(address) else { continue }
                    return Self(main: percent(info["device_batteryLevelMain"]), left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]), chargingCase: percent(info["device_batteryLevelCase"]))
                }
            }
        }
        return nil
    }
}

/// Local, read-only monitoring. No discovery, pairing, output switching, or BLE
/// packets. The expensive profiler runs only after a newly connected headset.
@MainActor final class HeadphoneConnection: NSObject, ObservableObject {
    static let shared = HeadphoneConnection()
    @Published private(set) var reading: ConnectedHeadphone?
    @Published private(set) var compact = false
    @Published private(set) var status = "耳机连接提示未启用"
    private let snapshot: () -> [ConnectedHeadphone]
    private let battery: @Sendable (String) async -> HeadphoneBattery?
    private let permitted: () -> Bool
    private let authorizationUndetermined: () -> Bool
    private let liveNotifications: Bool
    private var monitor: Task<Void, Never>?
    private var enrichment: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var known = Set<String>()
    private var notification: IOBluetoothUserNotification?
    private var enabled = false
    private var initialized = false

    init(snapshot: (() -> [ConnectedHeadphone])? = nil,
         battery: (@Sendable (String) async -> HeadphoneBattery?)? = nil,
         permitted: @escaping () -> Bool = { ![CBManagerAuthorization.denied, .restricted].contains(CBManager.authorization) },
         authorizationUndetermined: @escaping () -> Bool = { CBManager.authorization == .notDetermined }) {
        self.snapshot = snapshot ?? {
            (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
                guard device.isConnected(), let name = device.name, let address = device.addressString,
                      ConnectedHeadphone.isHeadphone(name: name, deviceClass: device.classOfDevice) else { return nil }
                return ConnectedHeadphone(id: ConnectedHeadphone.address(address), name: name)
            }
        }
        self.battery = battery ?? { address in
            guard let bytes = try? await NowPlayingBridge.run(program: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
                arguments: ["SPBluetoothDataType", "-json"], timeout: 5) else { return nil }
            return HeadphoneBattery.parse(bytes, address: address)
        }
        self.permitted = permitted
        self.authorizationUndetermined = authorizationUndetermined
        liveNotifications = snapshot == nil
        super.init()
    }

    func configure(enabled: Bool, allowAuthorizationPrompt: Bool = true) {
        guard enabled != self.enabled else { return }
        stop()
        guard enabled else { return }
        if !allowAuthorizationPrompt && authorizationUndetermined() {
            status = "耳机提示等待授权；请在设置中关闭后重新开启，按需授权蓝牙"
            return
        }
        self.enabled = true
        status = "正在监听耳机连接；电量由 macOS 提供"
        reconcile() // Baseline only: opening Island must not announce old connections.
        if liveNotifications && permitted() {
            notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.reconcile()
            }
        }
    }

    @objc nonisolated private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Task { @MainActor [weak self] in self?.reconcile() }
    }

    func reconcile() {
        guard enabled else { return }
        guard permitted() else {
            notification?.unregister(); notification = nil
            known.removeAll(); initialized = false; dismiss()
            status = "蓝牙访问未获授权；请在系统设置 → 隐私与安全性 → 蓝牙中允许 Nisla"
            return
        }
        status = "正在监听耳机连接；电量由 macOS 提供"
        let devices = snapshot().sorted { $0.id < $1.id }
        let current = Set(devices.map(\.id))
        defer { known = current; initialized = true }
        if let reading, !current.contains(reading.id) { dismiss() }
        guard initialized, let device = devices.first(where: { !known.contains($0.id) }) else { return }
        present(device)
        enrichment = Task { @MainActor [weak self, battery] in
            // Give macOS a moment to populate the battery after connection.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let levels = await battery(device.id)
            guard !Task.isCancelled, let self, self.enabled, self.reading?.id == device.id,
                  self.known.contains(device.id), let levels else { return }
            self.reading?.battery = levels
        }
    }

    // Also used by fixture-only UI tests; never initiates a hardware operation.
    func present(_ device: ConnectedHeadphone, duration: Duration = .seconds(6)) {
        dismiss()
        compact = false
        reading = device
        dismissal = Task { @MainActor [weak self] in
            let firstStage = duration * 0.55
            try? await Task.sleep(for: firstStage)
            guard !Task.isCancelled else { return }
            self?.compact = true
            try? await Task.sleep(for: duration - firstStage)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        enrichment?.cancel(); enrichment = nil
        dismissal?.cancel(); dismissal = nil
        reading = nil
        compact = false
    }

    func stop() {
        enabled = false
        notification?.unregister(); notification = nil
        monitor?.cancel(); monitor = nil
        known.removeAll(); initialized = false
        dismiss()
        status = "耳机连接提示已关闭"
    }
}

struct HeadphoneConnectionStatus: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var connection = HeadphoneConnection.shared
    var body: some View { Text(L10n.text(connection.status)).font(.caption).foregroundStyle(.secondary) }
}

struct HeadphoneConnectionBanner: View {
    @ObservedObject private var localization = AppLocalization.shared
    let device: ConnectedHeadphone
    let headerHeight: CGFloat
    var body: some View {
        HeadphoneNotificationBanner(device: device, headerHeight: headerHeight,
            track: nil, remoteArtwork: false, animateEntrance: false)
    }
}

/// The second stage fits in the collapsed notch: icon on the left, real
/// listening battery on the right. Music artwork stays in its own small island.
struct HeadphoneCompactBanner: View {
    @ObservedObject private var localization = AppLocalization.shared
    let device: ConnectedHeadphone
    let headerHeight: CGFloat
    let track: MusicTrack?
    let remoteArtwork: Bool

    var body: some View {
        HeadphoneNotificationBanner(device: device, headerHeight: headerHeight,
            track: track, remoteArtwork: remoteArtwork, animateEntrance: false).frame(height: headerHeight)
    }
}

/// One persistent hierarchy follows the native panel's actual height. The icon
/// and ring travel between their positions instead of being replaced by a
/// second compact view halfway through the window animation.
struct HeadphoneNotificationBanner: View {
    @ObservedObject private var localization = AppLocalization.shared
    let device: ConnectedHeadphone
    let headerHeight: CGFloat
    let track: MusicTrack?
    let remoteArtwork: Bool
    var animateEntrance = true
    var attached = true
    @State private var entered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasArtwork: Bool {
        track?.artwork != nil || (remoteArtwork && track?.artworkURL != nil)
    }

    var body: some View {
        GeometryReader { geometry in
            let expansion: CGFloat = min(1, max(0, (geometry.size.height - headerHeight) / 96))
            let accessory = hasArtwork ? 50 * (1 - expansion) : 0
            let surfaceWidth = max(0, geometry.size.width - accessory)
            let iconSize = 22 + 26 * expansion
            let ringSize = 20 + 26 * expansion
            let inset = 18 + 18 * expansion
            let centerY = headerHeight / 2 + (headerHeight / 2 + 48) * expansion
            let arrived = entered || !animateEntrance || reduceMotion
            ZStack(alignment: .topLeading) {
                NotchOutline(reveal: expansion, shoulders: attached, floating: !attached).fill(.black)
                    .frame(width: surfaceWidth, height: geometry.size.height)
                Image(systemName: device.symbol).resizable().scaledToFit().foregroundStyle(.white)
                    .frame(width: iconSize, height: iconSize)
                    .scaleEffect(arrived ? 1 : 0.74)
                    .rotation3DEffect(.degrees(arrived ? 0 : -12), axis: (x: 0, y: 1, z: 0))
                    .opacity(arrived ? 1 : 0)
                    .offset(y: arrived ? 0 : 6)
                    .position(x: inset + iconSize / 2, y: centerY)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("已连接")).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    Text(device.name).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    if let detail = device.battery.detail {
                        Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                .frame(width: max(0, surfaceWidth - 36 * 2 - 48 - 46 - 36), alignment: .leading)
                // Exit before the surface shrinks. A partially transparent,
                // compressed title looked like black text on the black notch.
                .opacity(arrived && HeadphoneBannerGeometry.showsText(expansion: expansion) ? 1 : 0)
                .animation(nil, value: expansion)
                .offset(y: arrived || reduceMotion ? 0 : 6)
                .position(x: (surfaceWidth + 2) / 2, y: centerY)
                .accessibilityHidden(!HeadphoneBannerGeometry.showsText(expansion: expansion))
                HeadphoneChargeIndicator(percentage: device.battery.percentage, expansion: expansion,
                    animateEntrance: animateEntrance)
                    .frame(width: ringSize, height: ringSize)
                    .position(x: surfaceWidth - inset - ringSize / 2, y: centerY)
                if hasArtwork {
                    MusicArtwork(track: track, remoteArtwork: remoteArtwork)
                        .frame(width: 23, height: 23).clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 42, height: headerHeight)
                        .background { RoundedRectangle(cornerRadius: 12).fill(Color.black) }
                        .scaleEffect(0.82 + 0.18 * (1 - expansion))
                        .opacity(pow(1 - Double(expansion), 3))
                        .position(x: geometry.size.width - 21, y: headerHeight / 2)
                        .accessibilityLabel(L10n.text("正在播放：\(track?.title ?? L10n.text("音乐"))"))
                        .accessibilityHidden(expansion > 0.2)
                }
            }
            .foregroundStyle(.white)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
        .task(id: device.id) {
            guard animateEntrance && !reduceMotion else { entered = true; return }
            entered = false
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.86)) { entered = true }
        }
        .accessibilityElement(children: .combine)
    }
}

enum HeadphoneBannerGeometry {
    static func showsText(expansion: CGFloat) -> Bool { expansion >= 0.9 }
}

private struct HeadphoneChargeIndicator: View {
    @ObservedObject private var localization = AppLocalization.shared
    let percentage: Int?
    let expansion: CGFloat
    let animateEntrance: Bool
    @State private var charge: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color { (percentage ?? 100) <= 20 ? .orange : .green }
    var body: some View {
        ZStack {
            if let percentage {
                Circle().stroke(tint.opacity(0.22 * Double(expansion)), lineWidth: 2.5 + 1.5 * expansion)
                Circle().trim(from: 0, to: animateEntrance && !reduceMotion ? charge : CGFloat(percentage) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5 + 1.5 * expansion, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percentage)").font(.system(size: 14 + 5 * expansion, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint).fixedSize()
                    .opacity(HeadphoneBannerGeometry.showsText(expansion: expansion) ? 1 : 0)
                    .animation(nil, value: expansion)
                    .contentTransition(.numericText())
            } else {
                Image(systemName: "checkmark.circle.fill").resizable().scaledToFit()
                    .foregroundStyle(.green).padding(3 + 5 * expansion)
            }
        }
        .accessibilityLabel(percentage.map { L10n.text("耳机电量 \($0)%") } ?? L10n.text("耳机已连接，电量未知"))
        .task(id: percentage) {
            guard let percentage else { charge = 0; return }
            let target = CGFloat(percentage) / 100
            guard animateEntrance && !reduceMotion else { charge = target; return }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.65, dampingFraction: 0.94)) { charge = target }
        }
    }
}
