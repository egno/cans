public extension ModelProfile {
    /// QC Ultra Headphones gen 1, verified on fw 1.6.7.
    static let qcUltra = ModelProfile(
        id: "qc-ultra-1",
        displayName: "QC Ultra Headphones",
        productIDs: [0x4066],
        rfcommChannel: 2,
        features: [.productName, .firmware, .modelName, .battery, .eq, .autoPause, .autoAnswer,
                   .multipoint, .modes, .pairedDevices],
        noiseControl: .modes(ModeLayout(slots: 0...9, presets: [
            ModePreset(index: 0, name: "Quiet", symbol: "waveform.slash", summary: "Full noise cancelling"),
            ModePreset(index: 1, name: "Aware", symbol: "ear", summary: "Hear your surroundings"),
            ModePreset(index: 2, name: "Immersion", symbol: "person.wave.2", summary: "Spatial audio"),
        ])),
        verified: true
    )
}
