import Foundation
import CoreAudio
import AudioToolbox

/// Thin CoreAudio wrapper: devices, default output/input, volume, mute, change notifications.
public final class AudioController {
    public struct Device: Equatable {
        public let id: AudioDeviceID
        public let name: String
        public let hasOutput: Bool
        public let hasInput: Bool
    }

    /// Called (on main queue) whenever default device, volume or mute changes.
    public var onChange: (() -> Void)?
    private var listenedDevices: Set<AudioDeviceID> = []

    public init() {}

    // MARK: - addresses
    private func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: - devices
    public func allDevices() -> [Device] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { Device(id: $0, name: name(of: $0), hasOutput: streamCount($0, kAudioObjectPropertyScopeOutput) > 0, hasInput: streamCount($0, kAudioObjectPropertyScopeInput) > 0) }
    }

    public func outputDevices() -> [Device] { allDevices().filter { $0.hasOutput } }
    public func inputDevices() -> [Device] { allDevices().filter { $0.hasInput } }

    private func streamCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    public func name(of id: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var cf: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        guard st == noErr, let s = cf?.takeRetainedValue() else { return "device \(id)" }
        return s as String
    }

    /// Case-insensitive substring match on device name.
    public func find(_ match: String, output: Bool) -> Device? {
        let m = match.lowercased()
        let list = output ? outputDevices() : inputDevices()
        return list.first { $0.name.lowercased() == m } ?? list.first { $0.name.lowercased().contains(m) }
    }

    // MARK: - defaults
    public func defaultOutput() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    public func defaultInput() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    private func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID? {
        var a = addr(sel)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    public func setDefaultOutput(_ id: AudioDeviceID) -> Bool { setDefault(kAudioHardwarePropertyDefaultOutputDevice, id) }
    @discardableResult
    public func setDefaultInput(_ id: AudioDeviceID) -> Bool { setDefault(kAudioHardwarePropertyDefaultInputDevice, id) }

    private func setDefault(_ sel: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
        var a = addr(sel)
        var v = id
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &v)
        if st != noErr { Log.error("setDefault \(sel) -> \(st)") }
        listenToDevices()
        return st == noErr
    }

    // MARK: - volume / mute (output scope)
    public func volume(of id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Float? {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    @discardableResult
    public func setVolume(_ value: Float, of id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        guard AudioObjectHasProperty(id, &a) else { Log.warn("device \(name(of: id)) has no main volume"); return false }
        var v = Float32(min(max(value, 0), 1))
        let st = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if st != noErr { Log.error("setVolume -> \(st)") }
        return st == noErr
    }

    public func isMuted(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool? {
        var a = addr(kAudioDevicePropertyMute, scope)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    @discardableResult
    public func setMuted(_ muted: Bool, of id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool {
        var a = addr(kAudioDevicePropertyMute, scope)
        guard AudioObjectHasProperty(id, &a) else { Log.warn("device \(name(of: id)) has no mute"); return false }
        var v: UInt32 = muted ? 1 : 0
        let st = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        if st != noErr { Log.error("setMuted -> \(st)") }
        return st == noErr
    }

    // MARK: - listeners
    public func startListening() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var a = addr(sel)
            AudioObjectAddPropertyListenerBlock(sys, &a, DispatchQueue.main) { [weak self] _, _ in
                self?.listenToDevices()
                self?.onChange?()
            }
        }
        listenToDevices()
    }

    private func listenToDevices() {
        for d in outputDevices() where !listenedDevices.contains(d.id) {
            listenedDevices.insert(d.id)
            for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var a = addr(sel, kAudioObjectPropertyScopeOutput)
                guard AudioObjectHasProperty(d.id, &a) else { continue }
                AudioObjectAddPropertyListenerBlock(d.id, &a, DispatchQueue.main) { [weak self] _, _ in self?.onChange?() }
            }
        }
    }
}
