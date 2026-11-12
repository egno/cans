import CoreAudio
import Foundation
import Observation

/// The Mac's audio output devices and which one is the default, kept current through
/// Core Audio listeners, so switching in Control Center or a pair's audio link coming
/// and going shows up at once.
///
/// Only the default output is changed; the system (alerts) output is left alone.
@MainActor @Observable
final class AudioOutput {
    struct Device: Equatable {
        let id: AudioObjectID
        let uid: String
        let name: String
        let isBluetooth: Bool
    }

    /// Devices with output streams.
    private(set) var devices: [Device] = []
    private(set) var defaultOutput: AudioObjectID?

    init() {
        reload()
        // Owned by the manager for the app's lifetime, so the listeners are never removed.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    /// The output device of the headphones with this Bluetooth address, if they're connected for audio.
    func device(forBluetoothAddress address: String) -> Device? {
        Self.device(forBluetoothAddress: address, in: devices)
    }

    func isDefault(_ device: Device) -> Bool {
        device.id == defaultOutput
    }

    func makeDefault(_ device: Device) throws {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &id)
        guard status == noErr else { throw AudioOutputError.status(status) }
        defaultOutput = device.id
    }

    // MARK: - Matching

    static func device(forBluetoothAddress address: String, in devices: [Device]) -> Device? {
        let wanted = normalized(address)
        return devices.first { $0.isBluetooth && bluetoothAddress(fromUID: $0.uid) == wanted }
    }

    /// Bluetooth devices' UIDs start with the address: "2C-41-A1-4D-B8-EB:output".
    /// Returns its 12 hex digits, lowercased, or nil for any other UID.
    static func bluetoothAddress(fromUID uid: String) -> String? {
        guard let head = uid.split(separator: ":").first,
              head.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let hex = normalized(String(head))
        return hex.count == 12 ? hex : nil
    }

    /// "2c-41-a1-4d-b8-eb" and "2C:41:A1:4D:B8:EB" both become "2c41a14db8eb".
    static func normalized(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }

    // MARK: - Core Audio

    private func reload() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        devices = Self.array(system, kAudioHardwarePropertyDevices).compactMap(Self.outputDevice)
        defaultOutput = Self.value(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
    }

    private static func outputDevice(_ id: AudioObjectID) -> Device? {
        // Inputs-only devices (a pair's hands-free mic, for one) have no output streams.
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport = value(id, kAudioDevicePropertyTransportType, as: UInt32.self)
        return Device(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                          || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func array(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// CFString properties come back retained.
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

enum AudioOutputError: LocalizedError {
    case status(OSStatus)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .status(let s): "macOS refused the change (error \(s))"
        case .notConnected: "they aren't connected to this Mac for audio"
        }
    }
}
