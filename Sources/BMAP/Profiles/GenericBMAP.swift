public extension ModelProfile {
    /// Fallback for unknown models: only requests every BMAP device seen so far
    /// answers. Carries the reported PID and name so the app can show them.
    static func generic(productID: UInt16? = nil, name: String? = nil) -> ModelProfile {
        let hex = productID.map { "0x" + String($0, radix: 16) }
        return ModelProfile(
            id: "generic",
            displayName: name ?? hex.map { "Bose headphones (\($0))" } ?? "Bose headphones",
            productIDs: productID.map { [$0] } ?? [],
            rfcommChannel: 2,
            features: [.productName, .firmware, .battery, .pairedDevices],
            noiseControl: nil,
            verified: false
        )
    }
}
