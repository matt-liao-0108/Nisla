import AppKit
import AudioToolbox
import Darwin

/// Hardware operations are only called for a recognized media key or a direct HUD slider interaction.
@MainActor final class SystemHardwareControls {
    private var softwareMuteLevels: [AudioDeviceID: Float32] = [:]
    private lazy var brightness = BuiltInBrightness()

    func adjust(_ key: SystemMediaKey, step: Double) -> SystemHUDReading? {
        switch key {
        case .volumeUp: adjustAudio(delta: Float32(step), mute: false)
        case .volumeDown: adjustAudio(delta: -Float32(step), mute: false)
        case .mute: adjustAudio(delta: 0, mute: true)
        case .brightnessUp: brightness.adjust(delta: Float32(step))
        case .brightnessDown: brightness.adjust(delta: -Float32(step))
        }
    }

    func set(_ kind: SystemHUDKind, value: Double) -> SystemHUDReading? {
        guard value.isFinite else { return nil }
        let target = Float32(min(1, max(0, value)))
        switch kind {
        case .volume:
            guard let endpoint = AudioEndpoint.current(), endpoint.writeLevel(target) else { return nil }
            if endpoint.muted == true && target > 0 {
                guard endpoint.canSetMute, endpoint.setMute(false) else {
                    endpoint.restoreLevels()
                    return nil
                }
            }
            softwareMuteLevels.removeValue(forKey: endpoint.device)
            return SystemHUDReading(kind: .volume, value: Double(target), muted: target == 0)
        case .brightness:
            return brightness.setLevel(target)
        }
    }

    private func adjustAudio(delta: Float32, mute: Bool) -> SystemHUDReading? {
        guard let endpoint = AudioEndpoint.current() else { return nil }
        if mute, let oldMuted = endpoint.muted, endpoint.canSetMute {
            guard endpoint.setMute(!oldMuted) else { return nil }
            return SystemHUDReading(kind: .volume, value: oldMuted ? Double(endpoint.level) : 0, muted: !oldMuted)
        }
        let target: Float32
        if mute {
            if let restore = softwareMuteLevels[endpoint.device], endpoint.level < 0.001 { target = restore }
            else { target = 0 }
        } else {
            let start = endpoint.muted == true ? 0 : endpoint.level
            target = min(1, max(0, start + delta))
        }
        guard endpoint.writeLevel(target) else { return nil }
        if endpoint.muted == true && target > 0 {
            guard endpoint.canSetMute, endpoint.setMute(false) else {
                endpoint.restoreLevels()
                return nil
            }
        }
        if mute && target == 0 { softwareMuteLevels[endpoint.device] = endpoint.level }
        else { softwareMuteLevels.removeValue(forKey: endpoint.device) }
        return SystemHUDReading(kind: .volume, value: Double(target), muted: target == 0)
    }
}

private struct AudioEndpoint {
    let device: AudioDeviceID
    let selector: AudioObjectPropertySelector
    let channels: [AudioObjectPropertyElement]
    let levels: [Float32]
    let muted: Bool?
    let canSetMute: Bool
    var level: Float32 { levels.max() ?? 0 }

    static func defaultDevice() -> AudioDeviceID? {
        var result = AudioDeviceID(0)
        var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &result) == noErr,
              result != kAudioObjectUnknown else { return nil }
        return result
    }

    static func current() -> Self? {
        guard let device = defaultDevice() else { return nil }
        let muteAddress = address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        let mutedValue: UInt32? = read(device, muteAddress, initial: UInt32(0))
        let writableMute = writable(device, muteAddress)
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            let main = address(selector, element: kAudioObjectPropertyElementMain)
            if writable(device, main), let value: Float32 = read(device, main, initial: Float32(0)), value.isFinite {
                return Self(device: device, selector: selector, channels: [kAudioObjectPropertyElementMain], levels: [value],
                    muted: mutedValue.map { $0 != 0 }, canSetMute: writableMute)
            }
        }
        // Preserve left/right balance when the device only exposes channel volume.
        let channels: [AudioObjectPropertyElement] = [1, 2]
        var values: [Float32] = []
        for channel in channels {
            let property = address(kAudioDevicePropertyVolumeScalar, element: channel)
            guard writable(device, property), let value: Float32 = read(device, property, initial: Float32(0)), value.isFinite else { return nil }
            values.append(value)
        }
        return Self(device: device, selector: kAudioDevicePropertyVolumeScalar, channels: channels, levels: values,
            muted: mutedValue.map { $0 != 0 }, canSetMute: writableMute)
    }

    func writeLevel(_ value: Float32) -> Bool {
        guard Self.defaultDevice() == device else { return false }
        for (index, channel) in channels.enumerated() {
            let target = channels.count == 1 || level < 0.001 ? value : value * levels[index] / level
            var safe = min(1, max(0, target))
            var property = Self.address(selector, element: channel)
            guard AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &safe) == noErr else {
                restoreLevels()
                return false
            }
        }
        return true
    }

    func restoreLevels() {
        for (index, channel) in channels.enumerated() {
            var value = levels[index]
            var property = Self.address(selector, element: channel)
            _ = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    func setMute(_ mute: Bool) -> Bool {
        guard Self.defaultDevice() == device else { return false }
        var value: UInt32 = mute ? 1 : 0
        var property = Self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
    private static func writable(_ device: AudioDeviceID, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var result = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &property) && AudioObjectIsPropertySettable(device, &property, &result) == noErr && result.boolValue
    }
    private static func read(_ device: AudioDeviceID, _ property: AudioObjectPropertyAddress, initial: Float32) -> Float32? {
        var property = property, result = initial
        var bytes = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &result) == noErr ? result : nil
    }
    private static func read(_ device: AudioDeviceID, _ property: AudioObjectPropertyAddress, initial: UInt32) -> UInt32? {
        var property = property, result = initial
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, &result) == noErr ? result : nil
    }
}

private final class BuiltInBrightness {
    typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float32>) -> Int32
    typealias Setter = @convention(c) (UInt32, Float32) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let get: Getter?
    private let set: Setter?

    init() {
        // Optional, private macOS API. Missing symbols disable only brightness takeover.
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        get = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
        set = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }
    }

    func adjust(delta: Float32) -> SystemHUDReading? {
        guard let get, let set else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        var current: Float32 = 0
        guard get(display, &current) == 0, current.isFinite else { return nil }
        let target = min(1, max(0, current + delta))
        guard set(display, target) == 0 else { return nil }
        return SystemHUDReading(kind: .brightness, value: Double(target))
    }

    func setLevel(_ target: Float32) -> SystemHUDReading? {
        guard let get, let set, target.isFinite else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        var current: Float32 = 0
        guard get(display, &current) == 0, current.isFinite else { return nil }
        let value = min(1, max(0, target))
        guard set(display, value) == 0 else { return nil }
        return SystemHUDReading(kind: .brightness, value: Double(value))
    }
}
