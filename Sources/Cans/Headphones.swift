import AppKit
import BMAP
import IOBluetooth
import Observation
import os

private let log = Logger(subsystem: "io.github.egno.cans", category: "headphones")

/// Live state of the connected headphones plus the actions the menu can perform.
///
/// Every packet from the device, whether a reply or an unsolicited notification,
/// goes through `apply(_:)`, so the UI reflects the headphones' own state.
@MainActor @Observable
final class Headphones {
    enum Status: Equatable {
        case searching
        case connected
        case unavailable
    }

    private(set) var status: Status = .searching
    private(set) var name: String?
    private(set) var firmware: String?
    private(set) var battery: Int?
    private(set) var modes: [ModeSlot] = []
    private(set) var currentMode: UInt8?
    private(set) var eq: [EQBand] = []
    private(set) var autoPause: Bool?
    private(set) var autoAnswer: Bool?
    private(set) var lastError: String?

    var announceModeChanges: Bool {
        didSet { UserDefaults.standard.set(announceModeChanges, forKey: Keys.announce) }
    }

    @ObservationIgnored private var client: BMAPClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var observers = Observers()

    private enum Keys {
        static let address = "lastDeviceAddress"
        static let announce = "announceModeChanges"
    }

    init() {
        announceModeChanges = UserDefaults.standard.object(forKey: Keys.announce) as? Bool ?? true
        observers.install { [weak self] in self?.reconnectSoon() }
        reconnectSoon()
    }

    // MARK: - Actions

    func selectMode(_ index: UInt8) {
        let previous = currentMode
        currentMode = index
        Task {
            do {
                let reply = try await send(Request.setMode(index, announce: announceModeChanges))
                if let idx = reply.payload.first { currentMode = idx }
            } catch {
                currentMode = previous
                report(error)
            }
        }
    }

    func setEQ(_ band: EQBand.Kind, value: Int) {
        Task { try? await send(Request.setEQ(band, value: value)) }
    }

    func setAutoPause(_ on: Bool) {
        Task { try? await send(Request.setToggle(.autoPause, on)) }
    }

    func setAutoAnswer(_ on: Bool) {
        Task { try? await send(Request.setToggle(.autoAnswer, on)) }
    }

    func refresh() {
        Task { await refreshAll() }
    }

    // MARK: - Device I/O

    @discardableResult
    private func send(_ packet: Packet) async throws -> Packet {
        guard let client else { throw BMAPError.disconnected }
        do {
            let reply = try await client.send(packet)
            apply(reply)
            return reply
        } catch {
            report(error)
            throw error
        }
    }

    private func apply(_ p: Packet) {
        guard p.op == .status || p.op == .result else { return }
        switch p.address {
        case .battery: battery = Decode.battery(p.payload)
        case .productName: name = Decode.productName(p.payload)
        case .firmware: firmware = Decode.string(p.payload)
        case .eq: eq = Decode.eq(p.payload)
        case .autoPause: autoPause = Decode.bool(p.payload)
        case .autoAnswer: autoAnswer = Decode.bool(p.payload)
        case .currentMode: if let m = Decode.currentMode(p.payload) { currentMode = m }
        case .modeConfig:
            guard let slot = Decode.modeSlot(p.payload) else { return }
            modes.removeAll { $0.index == slot.index }
            if !slot.isEmpty {
                modes.append(slot)
                modes.sort { $0.index < $1.index }
            }
        default: break
        }
    }

    private func refreshAll() async {
        for address in [Address.productName, .firmware, .battery, .eq, .autoPause, .autoAnswer, .currentMode] {
            _ = try? await client?.send(Request.get(address)).applying(apply)
        }
        // Slots 0-9: presets then custom; the device errors past the last slot.
        for index in UInt8(0)...9 {
            guard let reply = try? await client?.send(Request.get(.modeConfig, [index])) else { break }
            apply(reply)
        }
    }

    private func report(_ error: Error) {
        log.error("\(String(describing: error), privacy: .public)")
        lastError = String(describing: error)
    }

    // MARK: - Connection

    private func reconnectSoon() {
        guard client == nil, !isConnecting else { return }
        connectTask?.cancel()
        connectTask = Task { await connectLoop() }
    }

    private func connectLoop() async {
        var delay: Duration = .seconds(5)
        while client == nil, !Task.isCancelled {
            status = .searching
            if await connectToAnyCandidate() { return }
            status = .unavailable
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
    }

    private func connectToAnyCandidate() async -> Bool {
        isConnecting = true
        defer { isConnecting = false }
        for device in candidates() {
            let transport = RFCOMMTransport(device: device)
            do {
                try await transport.open()
                let c = BMAPClient(transport: transport)
                _ = try await c.send(Request.get(.productID))   // confirms it speaks BMAP
                log.info("connected to \(device.addressString ?? "?", privacy: .public)")
                attach(c)
                UserDefaults.standard.set(device.addressString, forKey: Keys.address)
                return true
            } catch {
                log.info("candidate \(device.addressString ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
                transport.close()
            }
        }
        return false
    }

    /// Paired audio devices, last-used first. `isConnected()` is unreliable on
    /// current macOS, so candidates are probed by opening the BMAP channel.
    private func candidates() -> [IOBluetoothDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.deviceClassMajor == kBluetoothDeviceClassMajorAudio }
        var seen = Set<String>()
        let unique = paired.filter { seen.insert($0.addressString ?? "").inserted }
        let last = UserDefaults.standard.string(forKey: Keys.address)
        return unique.filter { $0.addressString == last } + unique.filter { $0.addressString != last }
    }

    private func attach(_ c: BMAPClient) {
        client = c
        status = .connected
        lastError = nil
        c.onNotification = { [weak self] packet in
            log.info("notification \(packet.description, privacy: .public)")
            self?.apply(packet)
        }
        c.onClose = { [weak self] in self?.detach() }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                _ = try? await self?.send(Request.get(.battery))
                _ = try? await self?.send(Request.get(.currentMode))
            }
        }
    }

    private func detach() {
        log.info("disconnected")
        pollTask?.cancel()
        client = nil
        battery = nil
        currentMode = nil
        status = .unavailable
        reconnectSoon()
    }

    func shutdown() {
        pollTask?.cancel()
        connectTask?.cancel()
        client?.close()
    }
}

private extension Packet {
    func applying(_ f: (Packet) -> Void) -> Packet { f(self); return self }
}

/// System events that are good moments to retry the connection.
@MainActor
private final class Observers: NSObject {
    private var handler: (() -> Void)?
    private var btNotification: IOBluetoothUserNotification?

    func install(_ handler: @escaping () -> Void) {
        self.handler = handler
        btNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                    selector: #selector(deviceConnected(_:device:)))
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Give the headphones a moment to bring up their services.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.handler?()
        }
    }

    @objc private func didWake() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.handler?()
        }
    }
}
