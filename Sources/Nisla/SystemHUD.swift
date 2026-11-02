import SwiftUI
import AppKit
import ApplicationServices

@MainActor final class SystemHUD: ObservableObject {
    static let shared = SystemHUD()
    @Published private(set) var reading: SystemHUDReading?
    // Retain the last frame while the native panel retracts. The active reading
    // still clears immediately so AppDelegate can restore the original size.
    @Published private(set) var displayReading: SystemHUDReading?
    @Published private(set) var status = "系统提示接管未启用"
    @Published private(set) var authorized = false
    private let router: SystemHUDRouter
    private let setHardwareValue: (SystemHUDKind, Double) -> SystemHUDReading?
    private let isTrusted: () -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var dismissal: Task<Void, Never>?
    private var permissionWatch: Task<Void, Never>?
    private var timeoutDates: [Date] = []
    private var volume = false
    private var brightness = false
    private var sliderInteraction = false

    init(adjust: ((SystemMediaKey, Double) -> SystemHUDReading?)? = nil,
         setValue: ((SystemHUDKind, Double) -> SystemHUDReading?)? = nil,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
        if let adjust {
            router = SystemHUDRouter(adjust: adjust)
            setHardwareValue = setValue ?? { _, _ in nil }
        }
        else {
            let hardware = SystemHardwareControls()
            router = SystemHUDRouter { hardware.adjust($0, step: $1) }
            setHardwareValue = setValue ?? { hardware.set($0, value: $1) }
        }
    }

    func configure(volume: Bool, brightness: Bool) {
        self.volume = volume; self.brightness = brightness
        router.volumeEnabled = volume; router.brightnessEnabled = brightness
        authorized = isTrusted()
        guard volume || brightness else {
            stop(); status = "系统提示接管已关闭；按键由 macOS 处理"
            return
        }
        if permissionWatch == nil {
            permissionWatch = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    if self.isTrusted() != self.authorized {
                        self.configure(volume: self.volume, brightness: self.brightness)
                    }
                }
            }
        }
        guard authorized else {
            removeTap(); clear()
            status = "等待辅助功能授权；当前仍使用 macOS 原生提示"
            return
        }
        guard tap == nil else {
            status = "已接管已启用的媒体键；不支持的设备仍由系统处理"
            return
        }
        timeoutDates.removeAll()
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED only; never capture typed text.
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let hud = Unmanaged<SystemHUD>.fromOpaque(context).takeUnretainedValue()
            // This tap is attached only to the main run loop below.
            let consumed = MainActor.assumeIsolated { hud.receive(type: type, event: event) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            status = "无法启动媒体键接管；请检查辅助功能权限后重试。系统按键未被拦截。"
            return
        }
        tap = port; source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        status = "已接管已启用的媒体键；不支持的设备仍由系统处理"
    }

    func requestAuthorization() {
        // Called only by an explicit settings button; the user approves in macOS.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        configure(volume: volume, brightness: brightness)
    }

    func stop() {
        permissionWatch?.cancel(); permissionWatch = nil
        removeTap(); clear()
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; router.reset()
    }

    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            router.reset()
            guard isTrusted(), let tap else {
                removeTap(); clear()
                authorized = false
                status = "辅助功能权限不可用，已交还系统处理"
                return false
            }
            timeoutDates = timeoutDates.filter { Date.now.timeIntervalSince($0) < 10 }
            timeoutDates.append(.now)
            if timeoutDates.count >= 3 {
                removeTap(); clear()
                status = "接管响应不稳定，已暂停并交还系统；可在设置中重新检查"
            } else { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14, let input = NSEvent(cgEvent: event),
              let key = SystemMediaInput.decode(data1: input.data1, subtype: Int(input.subtype.rawValue),
                option: input.modifierFlags.contains(.option), shift: input.modifierFlags.contains(.shift),
                command: input.modifierFlags.contains(.command), control: input.modifierFlags.contains(.control)) else {
            return false
        }
        guard isTrusted() else {
            removeTap(); clear(); authorized = false
            status = "辅助功能权限已撤销，已交还系统处理"
            return false
        }
        let result = router.handle(key)
        if let reading = result.reading { present(reading) }
        else if key.down && !key.hasSystemShortcut && !result.consumed && (key.key.kind == .volume ? volume : brightness) {
            status = "当前设备或接口不支持此次接管，已保留 macOS 原生按键行为"
        }
        return result.consumed
    }

    /// Also used by isolated fixtures; this method never changes a hardware value.
    func present(_ value: SystemHUDReading, duration: Duration = .milliseconds(1400)) {
        guard value.value.isFinite else { return }
        dismissal?.cancel()
        displayReading = value
        reading = value
        status = "已在刘海显示\(value.kind == .volume ? "音量" : "屏幕亮度")"
        guard !sliderInteraction else { return }
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.reading = nil
            try? await Task.sleep(for: .seconds(IslandMotion.hudDuration(opening: false)))
            guard !Task.isCancelled else { return }
            self?.displayReading = nil
        }
    }

    func beginSliderInteraction(for kind: SystemHUDKind) {
        guard reading?.kind == kind else { return }
        sliderInteraction = true
        dismissal?.cancel()
        dismissal = nil
    }

    func setSliderValue(_ value: Double, for kind: SystemHUDKind) {
        guard sliderInteraction, reading?.kind == kind, value.isFinite,
              let updated = setHardwareValue(kind, min(1, max(0, value))),
              updated.kind == kind, updated.value.isFinite else { return }
        let safe = SystemHUDReading(kind: kind, value: min(1, max(0, updated.value)), muted: updated.muted)
        displayReading = safe
        reading = safe
    }

    func endSliderInteraction() {
        guard sliderInteraction else { return }
        sliderInteraction = false
        if let reading { present(reading) }
    }

    private func clear() { sliderInteraction = false; dismissal?.cancel(); dismissal = nil; reading = nil; displayReading = nil }

    /// A direct interaction (such as a file drop) dismisses only the toast;
    /// the enabled media-key capture must keep running.
    func dismissPresentation() { clear() }
}

struct SystemHUDLeading: View {
    @ObservedObject private var localization = AppLocalization.shared
    let reading: SystemHUDReading
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: reading.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 18)
            Text("\(reading.percentage)%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }.foregroundStyle(.white.opacity(0.9))
            .accessibilityLabel(L10n.text("\(reading.kind == .volume ? L10n.text("音量") : L10n.text("亮度")) \(reading.percentage)%"))
    }
}

struct SystemHUDTrailing: View {
    @ObservedObject private var localization = AppLocalization.shared
    let reading: SystemHUDReading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.17))
                Capsule().fill(.white.opacity(0.92)).frame(width: geometry.size.width * min(1, max(0, reading.value)))
            }.animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: reading.value)
        }.frame(maxWidth: 72).frame(height: 4).accessibilityHidden(true)
    }
}

/// A temporary, top-attached presentation. It never changes the selected page,
/// expansion preference; direct interaction with the progress track can adjust hardware.
struct SystemHUDNotificationBanner: View {
    @ObservedObject private var localization = AppLocalization.shared
    let reading: SystemHUDReading
    let headerHeight: CGFloat
    var appearance = "automatic"
    var attached = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var hud = SystemHUD.shared
    @State private var draggingSlider = false

    var body: some View {
        GeometryReader { geometry in
            let reveal = min(1, max(0, (geometry.size.height - headerHeight) / SystemHUDGeometry.extraHeight))
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.24),
                        .init(color: .black.opacity(0.84), location: 0.48),
                        .init(color: .black.opacity(0.42), location: 0.74),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .frame(height: headerHeight + 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                HStack(spacing: 12) {
                    Image(systemName: reading.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white.opacity(0.10)))
                    Text(reading.kind == .volume ? L10n.text("音量") : L10n.text("亮度"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    GeometryReader { track in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18)).frame(height: 5)
                            Capsule().fill(.white.opacity(0.92))
                                .frame(width: track.size.width * min(1, max(0, reading.value)))
                                .frame(height: 5)
                        }
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !draggingSlider {
                                    draggingSlider = true
                                    hud.beginSliderInteraction(for: reading.kind)
                                }
                                hud.setSliderValue(gesture.location.x / max(1, track.size.width), for: reading.kind)
                            }
                            .onEnded { _ in
                                draggingSlider = false
                                hud.endSliderInteraction()
                            })
                        .accessibilityElement()
                        .accessibilityLabel(reading.kind == .volume ? L10n.text("音量") : L10n.text("亮度"))
                        .accessibilityValue("\(reading.percentage)%")
                        .accessibilityAdjustableAction { direction in
                            let change: Double = direction == .increment ? 0.05 : -0.05
                            hud.beginSliderInteraction(for: reading.kind)
                            hud.setSliderValue(reading.value + change, for: reading.kind)
                            hud.endSliderInteraction()
                        }
                        .animation(draggingSlider || reduceMotion ? nil : .easeOut(duration: 0.10), value: reading.value)
                    }.frame(height: 28)
                    Text("\(reading.percentage)%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .fixedSize().frame(width: 36, alignment: .trailing)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: SystemHUDGeometry.extraHeight)
                .opacity(Double(reveal * reveal))
                .offset(y: headerHeight - (reduceMotion ? 0 : 4 * (1 - reveal)))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .modifier(ShelfMaterial(appearance: appearance, reveal: reveal,
                shape: NotchOutline(reveal: reveal, shoulders: attached, floating: !attached),
                shoulders: attached))
            .clipShape(NotchOutline(reveal: reveal, shoulders: attached, floating: !attached))
        }
        .environment(\.colorScheme, .dark)
        .onDisappear {
            if draggingSlider { draggingSlider = false; hud.endSliderInteraction() }
        }
    }
}

struct SystemHUDSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @EnvironmentObject private var store: PinStore
    @ObservedObject private var hud = SystemHUD.shared
    var body: some View {
        Section(L10n.text("系统音量与亮度提示（本地）")) {
            Toggle(L10n.text("接管音量 / 静音提示"), isOn: Binding(get: { store.options.hudVolumeEnabled ?? false }, set: { store.options.hudVolumeEnabled = $0 }))
            Toggle(L10n.text("接管内置屏幕亮度提示"), isOn: Binding(get: { store.options.hudBrightnessEnabled ?? false }, set: { store.options.hudBrightnessEnabled = $0 }))
            Text(L10n.text("默认关闭。启用并授权后，只拦截对应媒体键，不读取普通文字输入；按住可连续调整，Option + Shift 可微调。提示展开时可点击或拖动进度条直接调节，松开约 1.4 秒后收回并恢复原页面。连续按键不会反复展开；关闭或退出即恢复系统行为。")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("亮度仅支持活动的内置屏幕，使用非公开系统接口；外接屏、不支持软件音量的设备及未授权情况仍由系统处理。其他 App / 控制中心的调节不在本次按键接管范围内。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                if !hud.authorized {
                    Button(L10n.text("授权辅助功能…")) { hud.requestAuthorization() }
                }
                Button(L10n.text("重新检查 / 启动接管")) {
                    hud.configure(volume: store.options.hudVolumeEnabled ?? false, brightness: store.options.hudBrightnessEnabled ?? false)
                }
            }
            Text(L10n.text(hud.status)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
