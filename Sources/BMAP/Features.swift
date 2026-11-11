/// Feature addresses and payload codecs, verified on QC Ultra Headphones gen 1
/// (PID 0x4066, fw 1.6.7). See bose-probe/FINDINGS.md.

public extension Address {
    static let productID = Address(0, 3)
    static let firmware = Address(0, 5)
    static let modelName = Address(0, 15)
    static let productName = Address(1, 2)
    static let eq = Address(1, 7)
    static let multipoint = Address(1, 10)
    static let connectDevice = Address(4, 1)
    static let disconnectDevice = Address(4, 2)
    static let pairedDevices = Address(4, 4)
    static let deviceInfo = Address(4, 5)
    static let autoPause = Address(1, 24)
    static let autoAnswer = Address(1, 27)
    static let battery = Address(2, 2)
    static let currentMode = Address(31, 3)
    static let modeConfig = Address(31, 6)
}

public enum Request {
    public static func get(_ address: Address, _ payload: [UInt8] = []) -> Packet {
        Packet(address, .get, payload)
    }

    public static func setMode(_ index: UInt8, announce: Bool) -> Packet {
        Packet(.currentMode, .start, [index, announce ? 1 : 0])
    }

    public static func setEQ(_ band: EQBand.Kind, value: Int) -> Packet {
        let clamped = Int8(max(-10, min(10, value)))
        return Packet(.eq, .setGet, [UInt8(bitPattern: clamped), band.rawValue])
    }

    public static func setToggle(_ address: Address, _ enabled: Bool) -> Packet {
        Packet(address, .setGet, [enabled ? 1 : 0])
    }

    /// Replies PROCESSING, then RESULT once connected. With two devices already
    /// connected the headphones drop the one that isn't playing.
    public static func connect(_ device: DeviceAddress) -> Packet {
        Packet(.connectDevice, .start, [0] + device.bytes)
    }

    public static func disconnect(_ device: DeviceAddress) -> Packet {
        Packet(.disconnectDevice, .start, device.bytes)
    }

    public static func deviceInfo(_ device: DeviceAddress) -> Packet {
        Packet(.deviceInfo, .get, device.bytes)
    }
}

// MARK: - Decoded values

/// A 6-byte Bluetooth address as the headphones send it.
public struct DeviceAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ bytes: some Collection<UInt8>) {
        guard bytes.count == 6 else { return nil }
        self.bytes = Array(bytes)
    }

    /// Like IOBluetooth's `addressString`: "bc-89-c1-59-5b-fb".
    public var description: String {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined(separator: "-")
    }
}

public struct PairedDevices: Equatable, Sendable {
    /// Most recently used first.
    public let addresses: [DeviceAddress]
    public let connected: Set<DeviceAddress>
}

public struct DeviceInfo: Equatable, Sendable {
    public let address: DeviceAddress
    public let name: String
    public let isConnected: Bool
    /// The device the headphones are playing from.
    public let isActive: Bool
}

public struct EQBand: Equatable, Sendable, Identifiable {
    public enum Kind: UInt8, Sendable, CaseIterable {
        case bass = 0, mid = 1, treble = 2
        public var label: String {
            switch self {
            case .bass: "Bass"
            case .mid: "Mid"
            case .treble: "Treble"
            }
        }
    }

    public let kind: Kind
    public let range: ClosedRange<Int>
    public let value: Int
    public var id: UInt8 { kind.rawValue }

    public init(kind: Kind, range: ClosedRange<Int>, value: Int) {
        self.kind = kind
        self.range = range
        self.value = value
    }
}

public struct ModeSlot: Equatable, Sendable, Identifiable {
    public let index: UInt8
    public let name: String
    public var id: UInt8 { index }

    /// Firmware marks unused custom slots with the name "None".
    public var isEmpty: Bool { name.isEmpty || name == "None" }
}

public enum Decode {
    /// `[percent, ...]`; 0xff means unknown.
    public static func battery(_ p: [UInt8]) -> Int? {
        guard let v = p.first, v <= 100 else { return nil }
        return Int(v)
    }

    public static func string(_ p: [UInt8]) -> String {
        String(decoding: p.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// `[0x00, name bytes...]`
    public static func productName(_ p: [UInt8]) -> String {
        string(Array(p.dropFirst()))
    }

    /// Repeating `[min, max, value, band]` as signed bytes.
    public static func eq(_ p: [UInt8]) -> [EQBand] {
        stride(from: 0, to: p.count - p.count % 4, by: 4).compactMap { i in
            guard let kind = EQBand.Kind(rawValue: p[i + 3]) else { return nil }
            let lo = Int(Int8(bitPattern: p[i])), hi = Int(Int8(bitPattern: p[i + 1]))
            guard lo <= hi else { return nil }
            return EQBand(kind: kind, range: lo...hi, value: Int(Int8(bitPattern: p[i + 2])))
        }
    }

    /// `[index]`; 0xff means not yet known this session.
    public static func currentMode(_ p: [UInt8]) -> UInt8? {
        guard let v = p.first, v != 0xff else { return nil }
        return v
    }

    /// `[index, 5 bytes flags, name[32], settings...]`
    public static func modeSlot(_ p: [UInt8]) -> ModeSlot? {
        guard p.count >= 38 else { return nil }
        return ModeSlot(index: p[0], name: string(Array(p[6..<38])))
    }

    public static func bool(_ p: [UInt8]) -> Bool? {
        p.first.map { $0 != 0 }
    }

    /// `[connected bitmask over list positions, MAC × n]`, most recently used first.
    public static func pairedDevices(_ p: [UInt8]) -> PairedDevices? {
        guard let mask = p.first, (p.count - 1) % 6 == 0 else { return nil }
        let addresses = stride(from: 1, to: p.count, by: 6).compactMap { DeviceAddress(p[$0..<$0 + 6]) }
        let connected = addresses.indices.filter { $0 < 8 && mask & (1 << $0) != 0 }.map { addresses[$0] }
        return PairedDevices(addresses: addresses, connected: Set(connected))
    }

    /// `[MAC, status, 2 unknown bytes, name...]`; status bit 0 connected, bit 1 active.
    public static func deviceInfo(_ p: [UInt8]) -> DeviceInfo? {
        guard p.count >= 9, let address = DeviceAddress(p[0..<6]) else { return nil }
        return DeviceInfo(address: address, name: string(Array(p[9...])),
                          isConnected: p[6] & 0x01 != 0, isActive: p[6] & 0x02 != 0)
    }

    /// Multipoint: bit 0 is the setting (0x07 on, 0x06 off); bits 1-2 don't change with it.
    public static func multipoint(_ p: [UInt8]) -> Bool? {
        p.first.map { $0 & 0x01 != 0 }
    }
}
