import BMAP
import Foundation
import Observation

/// Which devices "This Mac Only" drops and which it can bring back. No Bluetooth here.
enum ThisMacOnlyPlan {
    /// Connected devices other than this Mac. Empty when this Mac isn't among the connected
    /// ones: then it can't be told apart, and dropping "the others" could drop Cans' own link.
    static func others(in devices: [DeviceInfo], isThisMac: (DeviceInfo) -> Bool) -> [DeviceInfo] {
        let connected = devices.filter(\.isConnected)
        guard connected.contains(where: isThisMac) else { return [] }
        return connected.filter { !isThisMac($0) }
    }

    /// Dropped devices that are still paired and can connect without pushing anything out:
    /// one spare connection with multipoint, none without.
    static func reconnectable(dropped: [String], in devices: [DeviceInfo], multipoint: Bool?) -> [DeviceInfo] {
        let limit = multipoint == false ? 1 : 2
        let free = limit - devices.filter(\.isConnected).count
        guard free > 0 else { return [] }
        return Array(devices.filter { !$0.isConnected && dropped.contains($0.address.description) }.prefix(free))
    }

    /// Dropped devices that haven't connected again since; the rest came back on their own
    /// or by hand, so there's nothing left to undo for them.
    static func stillDropped(_ dropped: [String], in devices: [DeviceInfo]) -> [String] {
        dropped.filter { address in devices.contains { $0.address.description == address && !$0.isConnected } }
    }
}

/// Disconnects the headphones' other devices so only this Mac stays, and remembers which
/// ones, per pair, to reconnect them later.
@MainActor @Observable
final class ThisMacOnly {
    /// Devices dropped, by the pair's address; kept across launches.
    private(set) var dropped: [String: [String]]

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "thisMacOnlyDropped"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dropped = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    /// The devices "This Mac Only" would disconnect.
    func others(of session: HeadphoneSession) -> [DeviceInfo] {
        guard session.profile.supports(.pairedDevices) else { return [] }
        return ThisMacOnlyPlan.others(in: session.devices, isThisMac: session.isThisMac)
    }

    /// The devices it dropped that can be connected again right now.
    func reconnectable(for session: HeadphoneSession) -> [DeviceInfo] {
        // Only next to this Mac; otherwise the list hasn't been read or isn't ours to judge.
        guard session.devices.contains(where: { $0.isConnected && session.isThisMac($0) }) else { return [] }
        return ThisMacOnlyPlan.reconnectable(dropped: dropped[session.address] ?? [], in: session.devices,
                                             multipoint: session.multipoint)
    }

    /// Disconnects every other device. Returns the ones it asked to leave.
    @discardableResult
    func engage(_ session: HeadphoneSession) -> [DeviceInfo] {
        let others = others(of: session)
        guard !others.isEmpty, session.pendingDevices.isEmpty else { return [] }
        remember(others.map(\.address.description), for: session)
        others.forEach(session.disconnect)
        return others
    }

    /// Connects what `engage` dropped. Returns the ones it asked back.
    @discardableResult
    func reconnect(_ session: HeadphoneSession) -> [DeviceInfo] {
        let back = reconnectable(for: session)
        guard !back.isEmpty, session.pendingDevices.isEmpty else { return [] }
        back.forEach(session.connect)
        return back
    }

    /// Call when the pair's device list changes.
    func forgetReconnected(_ session: HeadphoneSession) {
        guard let remembered = dropped[session.address], !session.devices.isEmpty else { return }
        // In the middle of our own disconnects the devices still read as connected.
        guard session.pendingDevices.isEmpty else { return }
        let still = ThisMacOnlyPlan.stillDropped(remembered, in: session.devices)
        if still != remembered { remember(still, for: session) }
    }

    private func remember(_ addresses: [String], for session: HeadphoneSession) {
        dropped[session.address] = addresses.isEmpty ? nil : addresses
        defaults.set(dropped, forKey: Self.key)
    }
}

/// "iPhone", "iPhone and iPad", "iPhone, iPad and Watch".
func listed(_ names: [String]) -> String {
    switch names.count {
    case 0: ""
    case 1: names[0]
    default: "\(names.dropLast().joined(separator: ", ")) and \(names.last!)"
    }
}
