public extension ModelProfile {
    /// QuietComfort 35 II. Reads verified on fw 4.8.1; writes (ANC, sidetone,
    /// action button, auto-off, voice prompts) follow bosectl and are untested,
    /// hence `verified: false`.
    ///
    /// Must never be asked for EQ [1.7]: it doesn't answer at all and the request
    /// times out. It has no fblock 31 modes and no model name [0.15]. Multipoint
    /// is always on with no toggle.
    static let qc35II = ModelProfile(
        id: "qc35-2",
        displayName: "QuietComfort 35 II",
        productIDs: [0x4020],
        rfcommChannel: 8,
        features: [.productName, .firmware, .battery, .ancLevel, .sidetone, .actionButton,
                   .autoOff, .voicePrompts, .pairedDevices],
        noiseControl: .ancLevels([.off, .low, .high]),
        verified: false
    )
}
