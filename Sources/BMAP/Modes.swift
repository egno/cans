/// Immersive audio and the fblock 31 mode table: custom modes, favourites and
/// "remember my mode". Read on QC Ultra Headphones gen 1 (fw 1.6.7); layouts
/// from the Bose app's own parser as recorded in bose-rfcomm, bossa and bosectl.
/// The mode write [31.6] and reset [31.9] were sent to that model; the
/// immersive audio and favourites writes were not.

/// Spatial audio setting, at [5.15] and inside each mode.
public enum ImmersiveAudio: UInt8, Sendable, CaseIterable {
    case off = 0
    /// Sound stays put when the head turns (fixed to the room).
    case still = 1
    /// Sound follows the head (fixed to the head).
    case motion = 2

    public var label: String {
        switch self {
        case .off: "Off"
        case .still: "Still"
        case .motion: "Motion"
        }
    }
}

/// One record of the mode table [31.6], as read. Never send a record back:
/// writes take a different, shorter shape (`ModeEdit`).
public struct ModeConfig: Equatable, Sendable, Identifiable {
    /// Which of a mode's settings the user may change.
    public struct Mutability: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let cncLevel = Mutability(rawValue: 1 << 0)
        public static let autoCNC = Mutability(rawValue: 1 << 1)
        public static let spatial = Mutability(rawValue: 1 << 2)
        public static let windBlock = Mutability(rawValue: 1 << 3)
        public static let ancToggle = Mutability(rawValue: 1 << 4)
    }

    public let index: UInt8
    /// Which word the headphones say for this mode; see `promptName`. 0 is silent.
    public let prompt: UInt16
    /// False for the built-in modes.
    public let userConfigurable: Bool
    public let userConfigured: Bool
    /// In the set the headphones' button cycles through.
    public let isFavorite: Bool
    public let name: String
    public let mutability: Mutability
    /// 0 is full noise cancelling, 10 full awareness.
    public let cncLevel: UInt8
    public let autoCNC: Bool
    /// Nil when the record is too short to carry it (earbuds) or the value is unknown.
    public let spatial: ImmersiveAudio?
    /// Nil when the record is too short to carry it.
    public let windBlock: Bool?

    public var id: UInt8 { index }
    public var slot: ModeSlot { ModeSlot(index: index, name: name) }

    /// An unused slot: no prompt and a placeholder name. A silent user mode has
    /// prompt 0 too, so the prompt alone doesn't say.
    public var isEmpty: Bool { prompt == 0 && slot.isEmpty }

    /// "Quiet", "Focus"; nil for a prompt this library doesn't know.
    public var promptName: String? { Self.promptName(prompt) }

    public static func promptName(_ prompt: UInt16) -> String? {
        Int(prompt) < promptNames.count ? promptNames[Int(prompt)] : nil
    }

    /// Spoken mode names by prompt id (bosectl PROMPTS). Quiet, Aware, Workout,
    /// Home, Focus and Immersion were seen on hardware.
    public static let promptNames = [
        "None", "Quiet", "Aware", "Transparent", "Transparency", "Masking", "Comfort", "Commute",
        "Outdoor", "Workout", "Home", "Work", "Music", "Focus", "Relax", "Flight", "Airport",
        "Driving", "Training", "Gym", "Run", "Walk", "Hike", "Talk", "Call", "Whisper", "Hearing",
        "Learn", "Podcast", "Audiobook", "Calm", "Sleep", "Meditate", "Yoga", "Immersion", "Stereo",
        "Cinema",
    ]
}

/// What a mode write [31.6] carries. Start from `init(editing:)` to change an
/// existing custom mode, or from the plain initializer to fill an empty slot.
public struct ModeEdit: Equatable, Sendable {
    /// Bytes of UTF-8 a mode name can hold: a 32-byte field that keeps a closing NUL.
    public static let maxNameBytes = 31
    public static let cncLevels: ClosedRange<UInt8> = 0...10

    public var index: UInt8
    /// `ModeConfig.promptNames` index; 0 for a mode the headphones don't announce.
    public var prompt: UInt16
    /// Cut to `maxNameBytes` on a character boundary when written.
    public var name: String
    /// 0 is full noise cancelling, 10 full awareness. Wind block forces 0.
    public var cncLevel: UInt8
    public var autoCNC: Bool
    public var spatial: ImmersiveAudio
    public var windBlock: Bool

    public init(index: UInt8, name: String, prompt: UInt16 = 0, cncLevel: UInt8 = 0, autoCNC: Bool = false,
                spatial: ImmersiveAudio = .off, windBlock: Bool = false) {
        self.index = index
        self.prompt = prompt
        self.name = name
        self.cncLevel = cncLevel
        self.autoCNC = autoCNC
        self.spatial = spatial
        self.windBlock = windBlock
    }

    /// The settings of a mode as read, field by field (not its bytes).
    public init(editing config: ModeConfig) {
        self.init(index: config.index, name: config.name, prompt: config.prompt, cncLevel: config.cncLevel,
                  autoCNC: config.autoCNC, spatial: config.spatial ?? .off, windBlock: config.windBlock ?? false)
    }

    /// 39 bytes: `[index, prompt hi, prompt lo, name[32], cncLevel, autoCNC, spatial, wind block]`.
    public var payload: [UInt8] {
        let nameBytes = Request.truncatedUTF8(name, maxBytes: Self.maxNameBytes)
        let level = windBlock ? 0 : min(cncLevel, Self.cncLevels.upperBound)
        return [index, UInt8(prompt >> 8), UInt8(prompt & 0xff)]
            + nameBytes + [UInt8](repeating: 0, count: 32 - nameBytes.count)
            + [level, autoCNC ? 1 : 0, spatial.rawValue, windBlock ? 1 : 0]
    }
}

/// The modes the headphones' button cycles through [31.8].
public struct Favorites: Equatable, Sendable {
    /// Size of the bitmask in modes. Not the number of slots in use; writes echo it.
    public let modeCount: UInt8
    public let modes: Set<UInt8>

    public init(modeCount: UInt8, modes: Set<UInt8>) {
        self.modeCount = modeCount
        self.modes = modes.filter { $0 < modeCount }
    }

    public func contains(_ index: UInt8) -> Bool { modes.contains(index) }

    /// A copy with one mode added or removed.
    public func setting(_ index: UInt8, favorite: Bool) -> Favorites {
        var modes = modes
        if favorite { modes.insert(index) } else { modes.remove(index) }
        return Favorites(modeCount: modeCount, modes: modes)
    }

    /// `[modeCount, mask...]`: mode m is bit m % 8 of the m / 8-th byte from the end.
    public var payload: [UInt8] {
        let size = (Int(modeCount) + 7) / 8
        var out = [UInt8](repeating: 0, count: 1 + size)
        out[0] = modeCount
        for m in modes where m < modeCount {
            out[size - Int(m) / 8] |= 1 << (m % 8)
        }
        return out
    }
}

public extension Request {
    /// Sets spatial audio directly [5.15]. Unverified: on a QC Ultra gen 1 the
    /// value was only seen to follow the mode; expect a possible error reply.
    static func setImmersiveAudio(_ mode: ImmersiveAudio) -> Packet {
        setGet(.immersiveAudio, [mode.rawValue])
    }

    /// Whether the headphones power on in the last mode used [31.5].
    static func setRememberMode(_ on: Bool) -> Packet {
        setToggle(.rememberMode, on)
    }

    /// Creates or changes a custom mode [31.6]. The reply is the slot's record in
    /// read format (`Decode.modeConfig`). Built-in modes refuse.
    static func setModeConfig(_ edit: ModeEdit) -> Packet {
        setGet(.modeConfig, edit.payload)
    }

    /// Unverified on a QC Ultra gen 1 (bossa writes this on the 2nd gen).
    static func setFavorites(_ favorites: Favorites) -> Packet {
        setGet(.favorites, favorites.payload)
    }

    /// Puts a slot back to its default [31.9], which deletes a custom mode for
    /// good. Replies RESULT; an index past the table is refused.
    static func resetMode(_ index: UInt8) -> Packet {
        Packet(.resetMode, .start, [index])
    }
}

public extension Decode {
    /// `[mode]`: 0 off, 1 still, 2 motion.
    static func immersiveAudio(_ p: [UInt8]) -> ImmersiveAudio? {
        p.first.flatMap(ImmersiveAudio.init(rawValue:))
    }

    /// The mode record: 47 bytes on a QC Ultra, 44 on earbuds, which stop before
    /// the spatial byte.
    ///
    ///     0      index               41  mutability bits
    ///     1-2    prompt id           42  cncLevel
    ///     3      userConfigurable    43  autoCNC
    ///     4      userConfigured      44  spatial      (if long enough)
    ///     5      favorite            46  wind block   (if long enough)
    ///     6-37   name, NUL-padded
    static func modeConfig(_ p: [UInt8]) -> ModeConfig? {
        guard p.count >= 44 else { return nil }
        return ModeConfig(index: p[0], prompt: UInt16(p[1]) << 8 | UInt16(p[2]),
                          userConfigurable: p[3] != 0, userConfigured: p[4] != 0, isFavorite: p[5] != 0,
                          name: string(Array(p[6..<38])), mutability: .init(rawValue: p[41]),
                          cncLevel: p[42], autoCNC: p[43] != 0,
                          spatial: p.count > 44 ? ImmersiveAudio(rawValue: p[44]) : nil,
                          windBlock: p.count > 46 ? p[46] != 0 : nil)
    }

    /// `[modeCount, mask...]`; `0a 00 1f` is modes 0-4 of 10.
    static func favorites(_ p: [UInt8]) -> Favorites? {
        guard let count = p.first, p.count >= 1 + (Int(count) + 7) / 8 else { return nil }
        let modes = (0..<count).filter { p[p.count - 1 - Int($0) / 8] & (1 << ($0 % 8)) != 0 }
        return Favorites(modeCount: count, modes: Set(modes))
    }
}
