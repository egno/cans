/// Feature addresses and payload codecs, verified on QC Ultra Headphones gen 1
/// (PID 0x4066, fw 1.6.7). See bose-probe/FINDINGS.md.

public extension Address {
    static let productID = Address(0, 3)
    static let firmware = Address(0, 5)
    static let productName = Address(1, 2)
    static let eq = Address(1, 7)
    static let multipoint = Address(1, 10)
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
}

// MARK: - Decoded values

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

    /// Multipoint: bit 1 means enabled.
    public static func multipoint(_ p: [UInt8]) -> Bool? {
        p.first.map { $0 & 0x02 != 0 }
    }
}
