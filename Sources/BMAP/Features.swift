/// Feature addresses and payload codecs. Unless noted, verified on QC Ultra
/// Headphones gen 1 (PID 0x4066, fw 1.6.7); see bose-probe/FINDINGS.md. The
/// fblock 1 settings marked QC35 II were read on a QC35 II (fw 4.8.1); their
/// write formats come from bosectl/based-connect and are untested.
/// Addresses are shared across Bose models; a `ModelProfile` says which exist.

public extension Address {
    static let bmapVersion = Address(0, 1)
    static let productID = Address(0, 3)
    static let firmware = Address(0, 5)
    static let modelName = Address(0, 15)
    static let productName = Address(1, 2)
    static let voicePrompts = Address(1, 3)     // QC35 II
    static let autoOff = Address(1, 4)          // QC35 II
    static let ancLevel = Address(1, 6)         // QC35 II
    static let actionButton = Address(1, 9)     // QC35 II, QC Ultra
    static let sidetone = Address(1, 11)        // QC35 II
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

    public static func setGet(_ address: Address, _ payload: [UInt8]) -> Packet {
        Packet(address, .setGet, payload)
    }

    public static func setToggle(_ address: Address, _ enabled: Bool) -> Packet {
        setGet(address, [enabled ? 1 : 0])
    }

    // Writes below follow bosectl/based-connect and haven't been tried on hardware.

    public static func setANC(_ level: ANCLevel) -> Packet {
        setGet(.ancLevel, [level.rawValue])
    }

    /// The leading 1 is the "enabled" byte the device reports back; level 0 turns it off.
    public static func setSidetone(_ level: SidetoneLevel) -> Packet {
        setGet(.sidetone, [1, level.rawValue])
    }

    /// `button` and `event` must echo what the device reported (`ActionButtonState`):
    /// each model has one configurable button and press.
    public static func setActionButton(_ action: ButtonAction, button: UInt8, event: UInt8) -> Packet {
        setGet(.actionButton, [button, event, action.rawValue])
    }

    /// `minutes` should be one of `AutoOff.choices`; others are likely rejected.
    public static func setAutoOff(minutes: UInt8) -> Packet {
        setGet(.autoOff, [minutes])
    }

    /// based-connect writes a single `[on bit | language]` byte, without the
    /// high bit the device reports (0xa1 reads back for on + US English).
    /// Untested; keep it behind a hardware check before exposing it.
    public static func setVoicePrompts(on: Bool, language: UInt8) -> Packet {
        setGet(.voicePrompts, [(on ? VoicePrompts.onBit : 0) | (language & VoicePrompts.languageMask)])
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

/// Noise cancelling level on models without fblock 31 modes. Raw values per bosectl.
public enum ANCLevel: UInt8, Sendable, CaseIterable {
    case off = 0, high = 1, wind = 2, low = 3

    /// Weakest to strongest, for pickers; raw values aren't in that order.
    public static let displayOrder: [ANCLevel] = [.off, .low, .high, .wind]

    public var label: String {
        switch self {
        case .off: "Off"
        case .high: "High"
        case .wind: "Wind"
        case .low: "Low"
        }
    }
}

public struct ANCState: Equatable, Sendable {
    /// Nil when the device reports a level this library doesn't know.
    public let level: ANCLevel?
    /// In `ANCLevel.displayOrder`.
    public let supported: [ANCLevel]

    public init(level: ANCLevel?, supported: [ANCLevel]) {
        self.level = level
        self.supported = supported
    }
}

public enum SidetoneLevel: UInt8, Sendable, CaseIterable {
    case off = 0, high = 1, medium = 2, low = 3

    public var label: String {
        switch self {
        case .off: "Off"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

public struct SidetoneState: Equatable, Sendable {
    public let level: SidetoneLevel?
    public let supported: [SidetoneLevel]

    public init(level: SidetoneLevel?, supported: [SidetoneLevel]) {
        self.level = level
        self.supported = supported
    }
}

/// What a configurable button press does (bosectl ACTION_MODES). A struct rather
/// than an enum so actions newer firmware reports still decode and can be kept.
public struct ButtonAction: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let notConfigured = ButtonAction(rawValue: 0)
    public static let voiceAssistant = ButtonAction(rawValue: 1)
    public static let noiseCancelling = ButtonAction(rawValue: 2)
    public static let batteryLevel = ButtonAction(rawValue: 3)
    public static let playPause = ButtonAction(rawValue: 4)
    public static let increaseNC = ButtonAction(rawValue: 5)
    public static let decreaseNC = ButtonAction(rawValue: 6)
    public static let toggleWakeWord = ButtonAction(rawValue: 7)
    public static let switchDevice = ButtonAction(rawValue: 8)
    public static let conversationMode = ButtonAction(rawValue: 9)
    public static let nextTrack = ButtonAction(rawValue: 10)
    public static let previousTrack = ButtonAction(rawValue: 11)
    public static let notifications = ButtonAction(rawValue: 12)
    public static let windMode = ButtonAction(rawValue: 13)
    public static let disabled = ButtonAction(rawValue: 14)
    public static let clientInteraction = ButtonAction(rawValue: 15)
    public static let spotifyTap = ButtonAction(rawValue: 16)
    public static let modesCarousel = ButtonAction(rawValue: 17)
    public static let volumePresets = ButtonAction(rawValue: 18)
    public static let spatialAudio = ButtonAction(rawValue: 19)
    public static let lineIn = ButtonAction(rawValue: 20)
    public static let linking = ButtonAction(rawValue: 21)
    public static let panicLocal = ButtonAction(rawValue: 22)
    public static let panicRemote = ButtonAction(rawValue: 23)
    public static let panicBoth = ButtonAction(rawValue: 24)
    public static let thirdPartyService = ButtonAction(rawValue: 25)
    public static let smartAction = ButtonAction(rawValue: 26)
    public static let alexa = ButtonAction(rawValue: 27)

    /// By raw value.
    private static let labels = [
        "Nothing", "Voice Assistant", "Noise Cancelling", "Battery Level", "Play/Pause",
        "More Noise Cancelling", "Less Noise Cancelling", "Wake Word", "Switch Device", "Conversation Mode",
        "Next Track", "Previous Track", "Notifications", "Wind Mode", "Disabled", "App Action",
        "Spotify Tap", "Cycle Modes", "Volume Presets", "Spatial Audio", "Line In", "Linking",
        "Panic (Local)", "Panic (Remote)", "Panic (Both)", "Third-Party Service", "Smart Action", "Alexa",
    ]

    /// "Action 30" for an action this library doesn't know.
    public var label: String {
        Int(rawValue) < Self.labels.count ? Self.labels[Int(rawValue)] : "Action \(rawValue)"
    }
}

/// The one configurable button press a model reports at [1.9]: the Action button's
/// single press on a QC35 II, the Shortcut button's long press on a QC Ultra.
public struct ActionButtonState: Equatable, Sendable {
    /// bosectl BUTTON_IDS; writes must echo these two.
    public let buttonID: UInt8
    /// bosectl BUTTON_EVENTS.
    public let event: UInt8
    public let action: ButtonAction
    /// In raw value order.
    public let supported: [ButtonAction]
    /// Supported but not usable right now (e.g. while LE Audio is active).
    public let unavailable: [ButtonAction]

    public init(buttonID: UInt8, event: UInt8, action: ButtonAction,
                supported: [ButtonAction], unavailable: [ButtonAction] = []) {
        self.buttonID = buttonID
        self.event = event
        self.action = action
        self.supported = supported
        self.unavailable = unavailable
    }

    public func with(action: ButtonAction) -> ActionButtonState {
        ActionButtonState(buttonID: buttonID, event: event, action: action,
                          supported: supported, unavailable: unavailable)
    }

    /// "Action button", "Shortcut button".
    public var buttonName: String {
        switch buttonID {
        case 0x00: "Noise cancelling button"
        case 0x02: "Voice assistant button"
        case 0x03: "Right shortcut button"
        case 0x04: "Left shortcut button"
        case 0x10: "Action button"
        case 0x80: "Shortcut button"
        default: "Button"
        }
    }

    /// "single press", "long press".
    public var eventName: String {
        switch event {
        case 1: "press"
        case 2: "release"
        case 3: "short press"
        case 4: "single press"
        case 5: "press and hold"
        case 6: "double press"
        case 7: "double press and hold"
        case 8: "triple press"
        case 9: "long press"
        case 10: "very long press"
        default: "press"
        }
    }
}

public enum AutoOff {
    /// Minutes; 0 means never.
    public static let choices: [UInt8] = [0, 5, 20, 40, 60, 180]
}

public struct VoicePrompts: Equatable, Sendable {
    static let onBit: UInt8 = 0x20
    static let languageMask: UInt8 = 0x1f

    public let isOn: Bool
    /// Index into `languageNames`; 1 is US English.
    public let language: UInt8
    /// The whole byte 0, so a writer can preserve bits we don't understand.
    public let raw: UInt8

    public var languageName: String? {
        Int(language) < Self.languageNames.count ? Self.languageNames[Int(language)] : nil
    }

    /// bosectl VOICE_LANGUAGES.
    public static let languageNames = [
        "UK English", "US English", "French", "Italian", "German", "EU Spanish", "MX Spanish",
        "BR Portuguese", "Mandarin", "Korean", "Russian", "Polish", "Hebrew", "Turkish", "Dutch",
        "Japanese", "Cantonese", "Arabic", "Swedish", "Danish", "Norwegian", "Finnish", "Hindi",
    ]
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

    /// `[pid hi, pid lo, variant]`: 0x40 0x20 0x01 is a QC35 II.
    public static func productID(_ p: [UInt8]) -> UInt16? {
        guard p.count >= 2 else { return nil }
        return UInt16(p[0]) << 8 | UInt16(p[1])
    }

    /// Values whose bit is set in `mask`, in `order`.
    static func supported<T: RawRepresentable<UInt8>>(_ mask: UInt8, in order: [T]) -> [T] {
        order.filter { $0.rawValue < 8 && mask & (1 << $0.rawValue) != 0 }
    }

    /// `[level, supported bitmask]`: `01 0b` is high, with off/high/low supported.
    public static func anc(_ p: [UInt8]) -> ANCState? {
        guard p.count >= 2 else { return nil }
        return ANCState(level: ANCLevel(rawValue: p[0]),
                        supported: supported(p[1], in: ANCLevel.displayOrder))
    }

    /// `[enabled, level, supported bitmask]`: `01 00 0f` is off, all four supported.
    public static func sidetone(_ p: [UInt8]) -> SidetoneState? {
        guard p.count >= 3 else { return nil }
        return SidetoneState(level: SidetoneLevel(rawValue: p[1]),
                             supported: supported(p[2], in: SidetoneLevel.allCases))
    }

    /// `[button, event, action, supported mask (1-4 bytes), unavailable mask (4 bytes), ...]`.
    /// QC35 II `10 04 02 07`: Action button single press is ANC, actions 0-2 supported.
    /// QC Ultra `80 09 13 00 09 40 0a`: Shortcut long press is spatial audio.
    public static func actionButton(_ p: [UInt8]) -> ActionButtonState? {
        guard p.count >= 4 else { return nil }
        let unavailable = p.count > 7 ? setBits(p[7..<min(p.count, 11)]) : []
        return ActionButtonState(buttonID: p[0], event: p[1], action: ButtonAction(rawValue: p[2]),
                                 supported: setBits(p[3..<min(p.count, 7)]).map(ButtonAction.init),
                                 unavailable: unavailable.map(ButtonAction.init))
    }

    /// Bit numbers set in a big-endian bitset: bit i is in the i/8-th byte from the end.
    static func setBits(_ mask: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(mask)
        return (0..<bytes.count * 8).filter { bytes[bytes.count - 1 - $0 / 8] & (1 << ($0 % 8)) != 0 }.map(UInt8.init)
    }

    /// `[minutes]`; 0 means never.
    public static func autoOff(_ p: [UInt8]) -> Int? {
        p.first.map(Int.init)
    }

    /// `[flags, ...]`: bit 5 on, low 5 bits language. The trailing bytes
    /// (`00 04 cf de` on a QC35 II) are not understood.
    public static func voicePrompts(_ p: [UInt8]) -> VoicePrompts? {
        guard let b = p.first else { return nil }
        return VoicePrompts(isOn: b & VoicePrompts.onBit != 0,
                            language: b & VoicePrompts.languageMask, raw: b)
    }
}
