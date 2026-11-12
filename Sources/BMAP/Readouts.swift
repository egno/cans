/// Read-only values: what's playing, where it plays from, and the full battery
/// record. Layouts read on QC Ultra Headphones gen 1 (fw 1.6.7).

/// Track metadata the source reports over AVRCP, relayed at [5.6].
///
/// Read by enumeration, not a GET: `BMAPClient.enumerate(Request.nowPlaying())`
/// returns one STATUS record per attribute. With nothing to report the device
/// answers no records, or a runtime error.
public struct NowPlaying: Equatable, Sendable {
    /// Record ids. Only these four were seen on hardware; other ids (1 and 2 are
    /// presumably artist and album) stay readable through `text(_:)`.
    public enum Attribute {
        public static let title: UInt8 = 0
        public static let trackNumber: UInt8 = 3
        public static let totalTracks: UInt8 = 4
        /// Named after bose-rfcomm's reading; the one sample was "0".
        public static let genre: UInt8 = 6
    }

    /// AVRCP's placeholder for an attribute the source doesn't have.
    static let placeholder = "Not Provided"

    /// Text by record id, as sent.
    public let attributes: [UInt8: String]

    public init(attributes: [UInt8: String] = [:]) {
        self.attributes = attributes
    }

    /// Nil when missing, empty or the "Not Provided" placeholder.
    public func text(_ id: UInt8) -> String? {
        guard let value = attributes[id], !value.isEmpty, value != Self.placeholder else { return nil }
        return value
    }

    public var title: String? { text(Attribute.title) }
    public var trackNumber: Int? { text(Attribute.trackNumber).flatMap { Int($0) } }
    public var totalTracks: Int? { text(Attribute.totalTracks).flatMap { Int($0) } }
    public var genre: String? { text(Attribute.genre) }

    /// True when no record has anything to show.
    public var isEmpty: Bool { attributes.keys.allSatisfy { text($0) == nil } }
}

/// Where the headphones are playing from [5.1].
public struct AudioSource: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case none = 0, bluetooth = 1, aux = 2
    }

    /// Nil for a source type this library doesn't know.
    public let kind: Kind?
    /// The playing device, for a Bluetooth source.
    public let device: DeviceAddress?
    /// The first two bytes, a mask of source types the model has (`00 0f` on a QC Ultra).
    public let supported: UInt16

    public init(kind: Kind?, device: DeviceAddress?, supported: UInt16) {
        self.kind = kind
        self.device = device
        self.supported = supported
    }
}

/// One record of [2.2]: a battery cell. Headphones have one, earbuds one per
/// bud plus the case.
public struct BatteryReading: Equatable, Sendable {
    /// Nil when the device reports 0xff (unknown).
    public let percent: Int?
    /// Play time left. Nil when the device reports `ffff`, which is all a
    /// QC Ultra gen 1 has been seen to send.
    public let minutesRemaining: Int?
    /// Which cell; nil on the one-byte record older models send.
    public let component: UInt8?

    public init(percent: Int?, minutesRemaining: Int?, component: UInt8?) {
        self.percent = percent
        self.minutesRemaining = minutesRemaining
        self.component = component
    }
}

public extension Request {
    /// Starts the now-playing enumeration [5.6]; send with `BMAPClient.enumerate`.
    static func nowPlaying() -> Packet {
        Packet(.nowPlaying, .start)
    }
}

public extension Decode {
    /// One now-playing record: `[id, text...]`.
    static func nowPlayingRecord(_ p: [UInt8]) -> (id: UInt8, text: String)? {
        guard let id = p.first else { return nil }
        return (id, string(Array(p.dropFirst())))
    }

    /// The records of one enumeration. Packets for other addresses are skipped.
    static func nowPlaying(_ records: [Packet]) -> NowPlaying {
        var attributes: [UInt8: String] = [:]
        for packet in records where packet.address == .nowPlaying {
            if let record = nowPlayingRecord(packet.payload) { attributes[record.id] = record.text }
        }
        return NowPlaying(attributes: attributes)
    }

    /// `[supported hi, supported lo, type, MAC × 6]`; `00 0f 00` with nothing attached.
    static func audioSource(_ p: [UInt8]) -> AudioSource? {
        guard p.count >= 3 else { return nil }
        let kind = AudioSource.Kind(rawValue: p[2])
        return AudioSource(kind: kind,
                           device: kind == .bluetooth && p.count >= 9 ? DeviceAddress(p[3..<9]) : nil,
                           supported: UInt16(p[0]) << 8 | UInt16(p[1]))
    }

    /// `[percent, minutes hi, minutes lo, component]` per cell; a lone `[percent]`
    /// on older models. `ffff` minutes means unknown.
    static func batteryReadings(_ p: [UInt8]) -> [BatteryReading] {
        func percent(_ v: UInt8) -> Int? { v <= 100 ? Int(v) : nil }
        guard p.count >= 4 else {
            return p.first.map { [BatteryReading(percent: percent($0), minutesRemaining: nil, component: nil)] } ?? []
        }
        return stride(from: 0, to: p.count - p.count % 4, by: 4).map { i in
            let minutes = Int(p[i + 1]) << 8 | Int(p[i + 2])
            return BatteryReading(percent: percent(p[i]), minutesRemaining: minutes == 0xffff ? nil : minutes,
                                  component: p[i + 3])
        }
    }
}
