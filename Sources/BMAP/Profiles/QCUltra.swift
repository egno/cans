public extension ModelProfile {
    /// QC Ultra Headphones gen 1, verified on fw 1.6.7. The Shortcut button
    /// setting [1.9] is read and written on hardware.
    ///
    /// Every read listed here answers on this model. Written on the same model
    /// and firmware elsewhere (bose-rfcomm), not yet from this app: self
    /// voice, auto-off, voice prompts, the name, remember-my-mode, custom modes
    /// and their reset. Not yet written on it: immersive audio [5.15] and
    /// favourites [31.8]. Power off, pairing mode and audio routing are only
    /// confirmed on the 2nd gen and may answer with an error.
    static let qcUltra = ModelProfile(
        id: "qc-ultra-1",
        displayName: "QC Ultra Headphones",
        productIDs: [0x4066],
        rfcommChannel: 2,
        features: [.productName, .firmware, .modelName, .battery, .eq, .autoPause, .autoAnswer,
                   .multipoint, .modes, .pairedDevices, .actionButton,
                   .sidetone, .autoOff, .voicePrompts, .serialNumber, .rename, .immersiveAudio,
                   .customModes, .rememberMode, .favorites, .nowPlaying, .audioSource,
                   .powerOff, .pairingMode, .audioRouting],
        noiseControl: .modes(ModeLayout(slots: 0...9, presets: [
            ModePreset(index: 0, name: "Quiet", symbol: "waveform.slash", summary: "Full noise cancelling"),
            ModePreset(index: 1, name: "Aware", symbol: "ear", summary: "Hear your surroundings"),
            ModePreset(index: 2, name: "Immersion", symbol: "person.wave.2", summary: "Spatial audio"),
        ])),
        verified: true,
        voicePromptsFormat: .flagsAndBatteryAnnouncement
    )
}
