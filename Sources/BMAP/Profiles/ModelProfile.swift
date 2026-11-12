/// What a headphone model supports. The BMAP core is shared; a profile only
/// says which features to request, so the app never sends a request a model
/// can't answer (some just time out instead of returning an error).

public enum Feature: Hashable, Sendable, CaseIterable {
    case productName, firmware, modelName, battery, eq, autoPause, autoAnswer, multipoint
    /// fblock 31: current mode and mode config.
    case modes
    case ancLevel, sidetone, actionButton, autoOff, voicePrompts
    /// [4.4] list, [4.5] device info, [4.1] connect, [4.2] disconnect.
    case pairedDevices

    /// [0.7] serial number, read with `Decode.string`.
    case serialNumber
    /// [1.2] accepts a new name (`Request.setProductName`).
    case rename
    /// [5.15] spatial audio: off, still or motion.
    case immersiveAudio
    /// [31.6] records carry the full mode (`Decode.modeConfig`), and custom
    /// modes can be written (`Request.setModeConfig`) and reset [31.9].
    case customModes
    /// [31.5] power on in the last mode used.
    case rememberMode
    /// [31.8] which modes the headphones' button cycles through.
    case favorites
    /// [5.6] track metadata, by `BMAPClient.enumerate(Request.nowPlaying())`.
    case nowPlaying
    /// [5.1] the device the headphones are playing from.
    case audioSource
    /// [7.4] `Request.powerOff`. This and the two below are confirmed on other
    /// models only: be ready for an error reply.
    case powerOff
    /// [4.8] `Request.setPairingMode`.
    case pairingMode
    /// [4.12] `Request.routeAudio(to:)` between two connected devices.
    case audioRouting
}

public struct ModelProfile: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let productIDs: Set<UInt16>
    /// Used when the SDP lookup for the BMAP channel fails.
    public let rfcommChannel: UInt8
    public let features: Set<Feature>
    public let noiseControl: NoiseControl?
    /// True when tested on hardware; false when assumed from other sources.
    public let verified: Bool
    /// The shape of a voice prompts write, for `Request.setVoicePrompts(_:format:)`.
    public let voicePromptsFormat: VoicePromptsFormat

    public init(id: String, displayName: String, productIDs: Set<UInt16>, rfcommChannel: UInt8,
                features: Set<Feature>, noiseControl: NoiseControl?, verified: Bool,
                voicePromptsFormat: VoicePromptsFormat = .flagsOnly) {
        self.voicePromptsFormat = voicePromptsFormat
        self.id = id
        self.displayName = displayName
        self.productIDs = productIDs
        self.rfcommChannel = rfcommChannel
        self.features = features
        self.noiseControl = noiseControl
        self.verified = verified
    }

    public func supports(_ feature: Feature) -> Bool { features.contains(feature) }
}

public enum NoiseControl: Sendable, Equatable {
    /// Named modes in fblock 31 slots (QC Ultra).
    case modes(ModeLayout)
    /// A fixed ANC level at [1.6] (QC35 II). The list is a default; the device's
    /// supported mask (`ANCState.supported`) replaces it at runtime.
    case ancLevels([ANCLevel])
}

public struct ModeLayout: Sendable, Equatable {
    public let slots: ClosedRange<UInt8>
    /// Built-in modes occupy the first slots; the rest are user modes.
    public let presets: [ModePreset]
    public var presetCount: Int { presets.count }

    public init(slots: ClosedRange<UInt8>, presets: [ModePreset]) {
        self.slots = slots
        self.presets = presets
    }

    /// Presentation for a slot; custom slots get a generic look.
    public func preset(at index: UInt8) -> ModePreset {
        presets.first { $0.index == index }
            ?? ModePreset(index: index, name: nil, symbol: "slider.horizontal.3", summary: "Custom mode")
    }
}

/// A built-in mode. `name` is the firmware's default name (users can't rename
/// presets, but the app shows whatever the device reports).
public struct ModePreset: Sendable, Equatable {
    public let index: UInt8
    public let name: String?
    /// SF Symbol name.
    public let symbol: String
    public let summary: String

    public init(index: UInt8, name: String?, symbol: String, summary: String) {
        self.index = index
        self.name = name
        self.symbol = symbol
        self.summary = summary
    }
}

public enum ModelRegistry {
    public static let all: [ModelProfile] = [.qcUltra, .qc35II]

    /// Falls back to a generic profile carrying the unknown PID.
    public static func profile(forProductID pid: UInt16, name: String? = nil) -> ModelProfile {
        all.first { $0.productIDs.contains(pid) } ?? .generic(productID: pid, name: name)
    }

    /// Distinct fallback channels, known models first, for discovery when SDP fails.
    public static var knownChannels: [UInt8] {
        var seen = Set<UInt8>()
        return (all.map(\.rfcommChannel) + [ModelProfile.generic().rfcommChannel]).filter { seen.insert($0).inserted }
    }
}

public extension ModelProfile {
    /// Single-request reads for this model's features, in refresh order: name first,
    /// so a low-battery notification can use it. Mode slots and paired devices take
    /// several requests each and are read separately.
    var settingAddresses: [Address] {
        let all: [(Feature, Address)] = [
            (.productName, .productName), (.modelName, .modelName), (.firmware, .firmware),
            (.battery, .battery), (.eq, .eq), (.autoPause, .autoPause), (.autoAnswer, .autoAnswer),
            (.multipoint, .multipoint), (.modes, .currentMode), (.ancLevel, .ancLevel),
            (.sidetone, .sidetone), (.actionButton, .actionButton), (.autoOff, .autoOff),
            (.voicePrompts, .voicePrompts), (.serialNumber, .serialNumber), (.audioSource, .audioSource),
            (.immersiveAudio, .immersiveAudio), (.rememberMode, .rememberMode), (.favorites, .favorites),
        ]
        return all.filter { supports($0.0) }.map(\.1)
    }

    /// Cheap reads repeated in the background: battery and the noise control state.
    var pollAddresses: [Address] {
        settingAddresses.filter { [.battery, .currentMode, .ancLevel].contains($0) }
    }
}
