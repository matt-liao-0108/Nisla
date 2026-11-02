import Foundation

enum SystemHUDKind: String, Sendable { case volume, brightness }

enum SystemHUDGeometry {
    static let extraHeight: CGFloat = 44
    static func size(notchWidth: CGFloat, headerHeight: CGFloat) -> CGSize {
        CGSize(width: max(340, notchWidth + 240), height: headerHeight + extraHeight)
    }
}

struct SystemHUDReading: Equatable, Sendable {
    let kind: SystemHUDKind
    let value: Double
    var muted = false

    var percentage: Int { Int(((value.isFinite ? min(1, max(0, value)) : 0) * 100).rounded()) }
    var symbol: String {
        switch kind {
        case .brightness: "sun.max.fill"
        case .volume: muted || value == 0 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
        }
    }
}

enum SystemMediaKey: Int, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    var kind: SystemHUDKind {
        switch self { case .volumeUp, .volumeDown, .mute: .volume; case .brightnessUp, .brightnessDown: .brightness }
    }
}

struct SystemMediaInput: Sendable {
    let key: SystemMediaKey
    let down: Bool
    let fine: Bool
    let hasSystemShortcut: Bool

    static func decode(data1: Int, subtype: Int, option: Bool, shift: Bool, command: Bool, control: Bool) -> Self? {
        guard subtype == 8, let key = SystemMediaKey(rawValue: (data1 >> 16) & 0xFFFF) else { return nil }
        let state = (data1 >> 8) & 0xFF
        guard state == 0xA || state == 0xB else { return nil }
        return Self(key: key, down: state == 0xA, fine: option && shift,
                    hasSystemShortcut: command || control || (option && !shift))
    }
}

struct SystemHUDDecision {
    let consumed: Bool
    var reading: SystemHUDReading?
    static let pass = Self(consumed: false)
}

/// Pure routing policy. No event tap, permission prompt or device access in tests.
@MainActor final class SystemHUDRouter {
    var volumeEnabled = false
    var brightnessEnabled = false
    private var captured = Set<SystemMediaKey>()
    private let adjust: (SystemMediaKey, Double) -> SystemHUDReading?

    init(adjust: @escaping (SystemMediaKey, Double) -> SystemHUDReading?) { self.adjust = adjust }
    func reset() { captured.removeAll() }

    func handle(_ input: SystemMediaInput) -> SystemHUDDecision {
        if !input.down {
            return Self.release(input.key, from: &captured)
        }
        guard !input.hasSystemShortcut,
              input.key.kind == .volume ? volumeEnabled : brightnessEnabled else {
            captured.remove(input.key)
            return .pass
        }
        // A held mute key must not repeatedly toggle the mute state.
        if input.key == .mute && captured.contains(.mute) { return SystemHUDDecision(consumed: true) }
        let step = input.fine ? 1.0 / 64 : 1.0 / 16
        guard let reading = adjust(input.key, step), reading.kind == input.key.kind, reading.value.isFinite else {
            captured.remove(input.key)
            return .pass
        }
        captured.insert(input.key)
        return SystemHUDDecision(consumed: true, reading: SystemHUDReading(kind: reading.kind,
            value: min(1, max(0, reading.value)), muted: reading.muted))
    }

    private static func release(_ key: SystemMediaKey, from captured: inout Set<SystemMediaKey>) -> SystemHUDDecision {
        SystemHUDDecision(consumed: captured.remove(key) != nil)
    }
}
