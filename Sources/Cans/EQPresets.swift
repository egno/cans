import BMAP
import Foundation
import Observation

/// A named setting of the three equalizer bands.
struct EQPreset: Codable, Equatable, Identifiable, Sendable {
    /// What every supported model's bands accept.
    static let range = -10...10

    let id: String
    var name: String
    var bass: Int
    var mid: Int
    var treble: Int

    init(id: String = UUID().uuidString, name: String, bass: Int, mid: Int, treble: Int) {
        let clamp = { (v: Int) in min(max(v, Self.range.lowerBound), Self.range.upperBound) }
        self.id = id
        self.name = name
        self.bass = clamp(bass)
        self.mid = clamp(mid)
        self.treble = clamp(treble)
    }

    /// The bands as the headphones report them; a band they don't have counts as 0.
    init(id: String = UUID().uuidString, name: String, bands: [EQBand]) {
        let value = { (kind: EQBand.Kind) in bands.first { $0.kind == kind }?.value ?? 0 }
        self.init(id: id, name: name, bass: value(.bass), mid: value(.mid), treble: value(.treble))
    }

    func value(for kind: EQBand.Kind) -> Int {
        switch kind {
        case .bass: bass
        case .mid: mid
        case .treble: treble
        }
    }

    /// The value to write to a band, kept inside what that band accepts.
    func value(for band: EQBand) -> Int {
        min(max(value(for: band.kind), band.range.lowerBound), band.range.upperBound)
    }

    /// The headphones' equalizer is set to this preset.
    func matches(_ bands: [EQBand]) -> Bool {
        !bands.isEmpty && bands.allSatisfy { $0.value == value(for: $0) }
    }

    /// "bass +6, mid 0, treble −2"
    var summary: String {
        EQBand.Kind.allCases.map { "\($0.label.lowercased()) \(signedValue(value(for: $0)))" }.joined(separator: ", ")
    }
}

private func signedValue(_ v: Int) -> String {
    v > 0 ? "+\(v)" : v < 0 ? "−\(-v)" : "0"
}

/// Built-in presets plus the user's own, which are kept in preferences for the app as a
/// whole rather than per pair: a preset is a taste, not a property of one headset.
@MainActor @Observable
final class EQPresetStore {
    static let builtIn: [EQPreset] = [
        EQPreset(id: "builtin.flat", name: "Flat", bass: 0, mid: 0, treble: 0),
        EQPreset(id: "builtin.bass-boost", name: "Bass boost", bass: 6, mid: 0, treble: 0),
        EQPreset(id: "builtin.bass-reducer", name: "Bass reducer", bass: -6, mid: 0, treble: 0),
        EQPreset(id: "builtin.treble-boost", name: "Treble boost", bass: 0, mid: 0, treble: 6),
        EQPreset(id: "builtin.vocal", name: "Vocal", bass: -3, mid: 4, treble: 1),
    ]

    /// The user's presets, in the order they were saved.
    private(set) var custom: [EQPreset]

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "eqPresets"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        custom = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([EQPreset].self, from: $0) } ?? []
    }

    var all: [EQPreset] { Self.builtIn + custom }

    func isBuiltIn(_ preset: EQPreset) -> Bool {
        Self.builtIn.contains { $0.id == preset.id }
    }

    /// The preset the equalizer is set to: a built-in first, then the user's.
    func match(_ bands: [EQBand]) -> EQPreset? {
        all.first { $0.matches(bands) }
    }

    /// Names are compared without case or surrounding spaces.
    func preset(named name: String) -> EQPreset? {
        let wanted = Self.normalized(name)
        return all.first { Self.normalized($0.name) == wanted }
    }

    /// Whether `name` can be given to a preset; `id` is the one being renamed, which may
    /// keep its own name. Built-in names are taken.
    func canUse(name: String, for id: String? = nil) -> Bool {
        let wanted = Self.normalized(name)
        guard !wanted.isEmpty else { return false }
        return !all.contains { Self.normalized($0.name) == wanted && $0.id != id }
    }

    /// Saves the bands under `name`. A preset of the user's with that name is replaced;
    /// nil when the name is empty or a built-in's.
    @discardableResult
    func save(name: String, bands: [EQBand]) -> EQPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = Self.normalized(trimmed)
        guard !wanted.isEmpty, !Self.builtIn.contains(where: { Self.normalized($0.name) == wanted }) else { return nil }
        if let index = custom.firstIndex(where: { Self.normalized($0.name) == wanted }) {
            custom[index] = EQPreset(id: custom[index].id, name: trimmed, bands: bands)
            persist()
            return custom[index]
        }
        let preset = EQPreset(name: trimmed, bands: bands)
        custom.append(preset)
        persist()
        return preset
    }

    /// False when the name is empty or taken, or the preset is a built-in.
    @discardableResult
    func rename(_ id: String, to name: String) -> Bool {
        guard let index = custom.firstIndex(where: { $0.id == id }), canUse(name: name, for: id) else { return false }
        custom[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
        return true
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.key)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension HeadphoneSession {
    /// Writes the bands that differ from the preset. Returns how many writes that took.
    @discardableResult
    func apply(_ preset: EQPreset) -> Int {
        let changes = eq.filter { $0.value != preset.value(for: $0) }
        changes.forEach { setEQ($0.kind, value: preset.value(for: $0)) }
        return changes.count
    }
}
