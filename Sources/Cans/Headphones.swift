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
    private(set) var model: String?
    private(set) var battery: Int?
    private(set) var modes: [ModeSlot] = []
    private(set) var currentMode: UInt8?
    private(set) var eq: [EQBand] = []
    private(set) var autoPause: Bool?
    private(set) var autoAnswer: Bool?
    private(set) var multipoint: Bool?
    /// Devices paired with the headphones, most recently used first.
    private(set) var devices: [DeviceInfo] = []
    /// Devices with a connect or disconnect in flight.
    private(set) var pendingDevices: [DeviceAddress: PendingChange] = [:]
    private(set) var lastError: String?
    /// False until the first full read after connecting, so the popover fills in once instead of row by row.
    private(set) var isLoaded = false
    /// Bumped when an EQ write fails, so sliders drop their unsent position.
    private(set) var eqRevision = 0

    enum PendingChange { case connect, disconnect }

    /// At or below this the battery shows in red and a notification is posted.
    static let lowBattery = BatteryAlerts.thresholds.max()!

    var isBatteryLow: Bool {
        battery.map { $0 <= Self.lowBattery } ?? false
    }

    var currentModeSlot: ModeSlot? {
        modes.first { $0.index == currentMode }
    }

    /// Remove the menu bar item while the headphones aren't connected.
    var hideWhenDisconnected: Bool {
        didSet {
            UserDefaults.standard.set(hideWhenDisconnected, forKey: Keys.hide)
            // Turned on while disconnected: keep the item until the next connect rather than
            // pulling the menu out from under the pointer.
            if hideWhenDisconnected, status != .connected { revealed = true }
        }
    }

    /// Set when the app is opened again while hidden, or when hiding is turned on while
    /// disconnected, so settings stay reachable; cleared on connect.
    private(set) var revealed = false

    var isInMenuBar: Bool {
        !hideWhenDisconnected || status == .connected || revealed
    }

    func reveal() { revealed = true }

    var announceModeChanges: Bool {
        didSet { UserDefaults.standard.set(announceModeChanges, forKey: Keys.announce) }
    }

    var lowBatteryAlerts: Bool {
        didSet {
            UserDefaults.standard.set(lowBatteryAlerts, forKey: Keys.lowBatteryAlerts)
            if lowBatteryAlerts { batteryAlerts.requestAuthorization() }
        }
    }

    @ObservationIgnored private var client: BMAPClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var observers = Observers()
    @ObservationIgnored private let batteryAlerts = BatteryAlerts()
    @ObservationIgnored private var errorDismissTask: Task<Void, Never>?
    @ObservationIgnored private var deviceRefreshTask: Task<Void, Never>?
    /// The headphones list this Mac among their devices. macOS formats it "BC:89:C1:59:5B:FB".
    @ObservationIgnored private let hostAddress = IOBluetoothHostController.default()?.addressAsString()
        .map { $0.lowercased().filter(\.isHexDigit) }

    func isThisMac(_ device: DeviceInfo) -> Bool {
        device.address.description.filter(\.isHexDigit) == hostAddress
    }

    private enum Keys {
        static let address = "lastDeviceAddress"
        static let announce = "announceModeChanges"
        static let hide = "hideWhenDisconnected"
        static let lowBatteryAlerts = "lowBatteryAlerts"
    }

    init() {
        announceModeChanges = UserDefaults.standard.object(forKey: Keys.announce) as? Bool ?? true
        hideWhenDisconnected = UserDefaults.standard.bool(forKey: Keys.hide)
        lowBatteryAlerts = UserDefaults.standard.object(forKey: Keys.lowBatteryAlerts) as? Bool ?? true
        if lowBatteryAlerts { batteryAlerts.requestAuthorization() }
        observers.install { [weak self] in self?.reconnectSoon() }
        reconnectSoon()
    }

    // MARK: - Actions

    func selectMode(_ index: UInt8) {
        let previous = currentMode
        currentMode = index
        Task {
            do {
                let reply = try await send(Request.setMode(index, announce: announceModeChanges),
                                           failing: "switch mode")
                if let idx = reply.payload.first { currentMode = idx }
            } catch {
                currentMode = previous
            }
        }
    }

    func setEQ(_ band: EQBand.Kind, value: Int) {
        Task {
            do {
                try await send(Request.setEQ(band, value: value), failing: "change the equalizer")
            } catch {
                eqRevision += 1
            }
        }
    }

    func setAutoPause(_ on: Bool) {
        Task { try? await send(Request.setToggle(.autoPause, on), failing: "change auto-pause") }
    }

    func setAutoAnswer(_ on: Bool) {
        Task { try? await send(Request.setToggle(.autoAnswer, on), failing: "change auto-answer") }
    }

    func setMultipoint(_ on: Bool) {
        Task { try? await send(Request.setToggle(.multipoint, on), failing: "change multipoint") }
    }

    func connect(_ device: DeviceInfo) {
        changeConnection(of: device, .connect)
    }

    func disconnect(_ device: DeviceInfo) {
        changeConnection(of: device, .disconnect)
    }

    /// The headphones answer PROCESSING at once and RESULT (or ERROR) when done,
    /// which `handleDeviceEvent` picks up. The timeout covers a result that never comes.
    private func changeConnection(of device: DeviceInfo, _ change: PendingChange) {
        let address = device.address
        let request = change == .connect ? Request.connect(address) : Request.disconnect(address)
        pendingDevices[address] = change
        Task {
            do {
                try await send(request, failing: Self.describe(change, displayName(of: device)))
            } catch {
                pendingDevices[address] = nil
                return
            }
            try? await Task.sleep(for: .seconds(20))
            if pendingDevices.removeValue(forKey: address) != nil {
                report(BMAPError.timeout(request.address), action: Self.describe(change, displayName(of: device)))
                await loadDevices()
            }
        }
    }

    func displayName(of device: DeviceInfo) -> String {
        isThisMac(device) ? "this Mac" : device.name
    }

    private static func describe(_ change: PendingChange, _ name: String) -> String {
        "\(change == .connect ? "connect" : "disconnect") \(name)"
    }

    /// Skips the backoff wait and looks for the headphones now.
    func retryNow() {
        guard client == nil, !isConnecting else { return }
        status = .searching
        connectTask?.cancel()
        connectTask = Task { await connectLoop() }
    }

    /// For problems outside the headphones, such as launch at login.
    func showProblem(_ message: String) {
        showError(message)
    }

    func refreshDevices() {
        Task { await loadDevices() }
    }

    func dismissError() {
        errorDismissTask?.cancel()
        lastError = nil
    }

    func refresh() {
        Task { await refreshAll() }
    }

    // MARK: - Device I/O

    @discardableResult
    private func send(_ packet: Packet, failing action: String) async throws -> Packet {
        do {
            guard let client else { throw BMAPError.disconnected }
            let reply = try await client.send(packet)
            apply(reply)
            return reply
        } catch {
            report(error, action: action)
            throw error
        }
    }

    private func apply(_ p: Packet) {
        if p.address.fblock == Address.pairedDevices.fblock { handleDeviceEvent(p) }
        guard p.op == .status || p.op == .result else { return }
        switch p.address {
        case .battery:
            battery = Decode.battery(p.payload)
            if lowBatteryAlerts, let battery { batteryAlerts.update(battery: battery, deviceName: name) }
        case .productName: name = Decode.productName(p.payload)
        case .firmware: firmware = Decode.string(p.payload)
        case .modelName: model = Decode.string(p.payload)
        case .eq: eq = Decode.eq(p.payload)
        case .autoPause: autoPause = Decode.bool(p.payload)
        case .autoAnswer: autoAnswer = Decode.bool(p.payload)
        case .multipoint: multipoint = Decode.multipoint(p.payload)
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

    /// Connection results and device changes the headphones report on their own.
    private func handleDeviceEvent(_ p: Packet) {
        switch (p.address, p.op) {
        case (.connectDevice, .result), (.disconnectDevice, .result):
            if let address = DeviceAddress(p.payload.suffix(6)) { pendingDevices[address] = nil }
            scheduleDeviceRefresh()
        case (.connectDevice, .error), (.disconnectDevice, .error):
            // The error carries no address; name the device when only one change was in flight.
            let change: PendingChange = p.address == .connectDevice ? .connect : .disconnect
            let matching = pendingDevices.filter { $0.value == change }.map(\.key)
            let name = matching.count == 1
                ? devices.first { $0.address == matching[0] }.map(displayName(of:)) : nil
            matching.forEach { pendingDevices[$0] = nil }
            let code = p.payload.first.flatMap(DeviceErrorCode.init(rawValue:))
            report(BMAPError.device(p.address, code), action: Self.describe(change, name ?? "the device"))
            scheduleDeviceRefresh()
        case (_, .status) where p.address != .deviceInfo && p.address != .pairedDevices:
            scheduleDeviceRefresh()
        default:
            break
        }
    }

    /// Several device events tend to arrive together; reload the list once.
    private func scheduleDeviceRefresh() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadDevices()
        }
    }

    private func loadDevices() async {
        guard let client,
              let reply = try? await client.send(Request.get(.pairedDevices)),
              let paired = Decode.pairedDevices(reply.payload) else { return }
        var loaded: [DeviceInfo] = []
        for address in paired.addresses {
            if let reply = try? await client.send(Request.deviceInfo(address)),
               let info = Decode.deviceInfo(reply.payload) {
                loaded.append(info)
            }
        }
        devices = loaded
    }

    private func refreshAll() async {
        // Name first, so a low-battery notification can use it.
        var failures: [Error] = []
        for address in [Address.productName, .modelName, .firmware, .battery, .eq,
                        .autoPause, .autoAnswer, .multipoint, .currentMode] {
            guard let client else { return }
            do {
                apply(try await client.send(Request.get(address)))
            } catch {
                log.error("refresh \(address, privacy: .public): \(String(describing: error), privacy: .public)")
                failures.append(error)
            }
        }
        if let first = failures.first {
            report(first, action: failures.count == 1 ? "read a setting" : "read \(failures.count) settings")
        }
        // Slots 0-9: presets then custom; the device errors past the last slot.
        // Collected first so the list appears in one step.
        var slots: [ModeSlot] = []
        for index in UInt8(0)...9 {
            guard let reply = try? await client?.send(Request.get(.modeConfig, [index])),
                  let slot = Decode.modeSlot(reply.payload) else { break }
            if !slot.isEmpty { slots.append(slot) }
        }
        if client != nil { modes = slots }
        await loadDevices()
        if client != nil { isLoaded = true }
    }

    /// Shows "Couldn't <action>: <reason>" in the popover for a few seconds.
    private func report(_ error: Error, action: String) {
        log.error("couldn't \(action, privacy: .public): \(String(describing: error), privacy: .public)")
        showError("Couldn't \(action): \(Self.reason(for: error))")
    }

    private func showError(_ message: String) {
        lastError = message
        errorDismissTask?.cancel()
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    private static func reason(for error: Error) -> String {
        switch error as? BMAPError {
        case .disconnected: "headphones aren't connected"
        case .timeout: "headphones didn't respond"
        case .malformed: "unexpected reply from the headphones"
        case .device(_, let code):
            switch code {
            case .functionNotSupported, .fblockNotSupported, .operatorNotSupported:
                "not supported by these headphones"
            case .invalidState, .invalidTransition: "not possible right now"
            default: "headphones reported an error"
            }
        case nil: error.localizedDescription
        }
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
            // Background retries keep showing "Not connected" instead of flickering to "Connecting…".
            if status != .unavailable { status = .searching }
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
        revealed = false
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
                // Background reads stay out of the popover; a dead link shows up as a disconnect.
                for address in [Address.battery, .currentMode] {
                    guard let self, let client = self.client else { return }
                    if let reply = try? await client.send(Request.get(address)) { self.apply(reply) }
                }
            }
        }
    }

    private func detach() {
        log.info("disconnected")
        pollTask?.cancel()
        client = nil
        battery = nil
        currentMode = nil
        devices = []
        pendingDevices = [:]
        autoPause = nil
        autoAnswer = nil
        multipoint = nil
        isLoaded = false
        status = .unavailable
        reconnectSoon()
    }

    func shutdown() {
        pollTask?.cancel()
        connectTask?.cancel()
        client?.close()
    }
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
