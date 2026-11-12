import BMAP
import IOBluetooth
import Observation
import os

private let log = Logger(subsystem: "io.github.egno.cans", category: "headphones")

/// What a session needs from whoever owns it.
@MainActor
protocol SessionHost: AnyObject {
    var announceModeChanges: Bool { get }
    var lowBatteryAlerts: Bool { get }
    /// Called for failures the user should see; the host decides how to show them.
    func session(_ session: HeadphoneSession, couldNot action: String, because error: Error)
    func sessionDidClose(_ session: HeadphoneSession)
}

/// Live state of one connected pair of headphones plus the actions the menu can perform on it.
///
/// Every packet from the device, whether a reply or an unsolicited notification,
/// goes through `apply(_:)`, so the UI reflects the headphones' own state. Only
/// the features in `profile` are ever requested.
@MainActor @Observable
final class HeadphoneSession {
    enum PendingChange { case connect, disconnect }

    /// The headphones' Bluetooth address as IOBluetooth formats it ("bc-89-c1-59-5b-fb").
    let address: String
    let profile: ModelProfile

    private(set) var name: String?
    private(set) var firmware: String?
    private(set) var model: String?
    private(set) var battery: Int?
    private(set) var modes: [ModeSlot] = []
    private(set) var currentMode: UInt8?
    private(set) var anc: ANCState?
    private(set) var eq: [EQBand] = []
    private(set) var autoPause: Bool?
    private(set) var autoAnswer: Bool?
    private(set) var multipoint: Bool?
    private(set) var sidetone: SidetoneState?
    private(set) var actionButton: ActionButtonState?
    /// Minutes; 0 means never.
    private(set) var autoOff: Int?
    private(set) var voicePrompts: VoicePrompts?
    /// Devices paired with the headphones, most recently used first.
    private(set) var devices: [DeviceInfo] = []
    /// Devices with a connect or disconnect in flight.
    private(set) var pendingDevices: [DeviceAddress: PendingChange] = [:]
    /// False until the first full read after connecting, so the popover fills in once instead of row by row.
    private(set) var isLoaded = false
    /// Bumped when an EQ write fails, so sliders drop their unsent position.
    private(set) var eqRevision = 0

    /// At or below this the battery shows in red and a notification is posted.
    static let lowBattery = BatteryAlerts.thresholds.max()!

    var isBatteryLow: Bool {
        battery.map { $0 <= Self.lowBattery } ?? false
    }

    /// The name the user gave the headphones, or the model until it's read.
    var displayName: String { name ?? profile.displayName }

    var modelName: String { model ?? profile.displayName }

    var modeLayout: ModeLayout? {
        if case .modes(let layout) = profile.noiseControl, profile.supports(.modes) { return layout }
        return nil
    }

    var currentModeSlot: ModeSlot? {
        modes.first { $0.index == currentMode }
    }

    /// "Quiet mode" or "Noise cancelling high"; nil when the state isn't known.
    var noiseControlSummary: String? {
        if let mode = currentModeSlot { return "\(mode.name) mode" }
        if profile.supports(.ancLevel), let level = anc?.level { return "Noise cancelling \(level.label.lowercased())" }
        return nil
    }

    /// Anything for the Controls section: supported and read. Models with modes always
    /// have one, the announce-mode-changes switch.
    var hasControls: Bool {
        modeLayout != nil
            || (profile.supports(.autoPause) && autoPause != nil)
            || (profile.supports(.autoAnswer) && autoAnswer != nil)
            || (profile.supports(.sidetone) && sidetone != nil)
            || (profile.supports(.actionButton) && actionButton != nil)
            || (profile.supports(.autoOff) && autoOff != nil)
            || (profile.supports(.voicePrompts) && voicePrompts != nil)
    }

    @ObservationIgnored private let client: BMAPClient
    @ObservationIgnored private weak var host: SessionHost?
    @ObservationIgnored private let batteryAlerts: BatteryAlerts
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var deviceRefreshTask: Task<Void, Never>?
    /// Waits for connect/disconnect results that never came; cancelled on close.
    @ObservationIgnored private var pendingTimeouts: [DeviceAddress: Task<Void, Never>] = [:]
    /// Set once the channel is gone; a closed session is never kept by the manager.
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var lastReload: ContinuousClock.Instant?

    /// The headphones list this Mac among their devices. macOS formats it "BC:89:C1:59:5B:FB".
    private static let hostAddress = IOBluetoothHostController.default()?.addressAsString()
        .map { $0.lowercased().filter(\.isHexDigit) }

    init(client: BMAPClient, profile: ModelProfile, address: String, host: SessionHost, batteryAlerts: BatteryAlerts) {
        self.client = client
        self.profile = profile
        self.address = address
        self.host = host
        self.batteryAlerts = batteryAlerts
        client.onNotification = { [weak self] packet in
            log.info("notification \(packet.description, privacy: .public)")
            self?.apply(packet)
        }
        client.onClose = { [weak self] in self?.didClose() }
        // The channel can drop between the product ID reply and here, before onClose was set.
        isClosed = client.isClosed
    }

    /// Reads everything, then keeps battery and noise control fresh in the background.
    func start() {
        guard !isClosed else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                // Background reads stay out of the popover; a dead link shows up as a disconnect.
                guard let addresses = self?.profile.pollAddresses else { return }
                for address in addresses {
                    guard let self, !self.isClosed else { return }
                    if let reply = try? await self.client.send(Request.get(address)) { self.apply(reply) }
                }
            }
        }
    }

    func close() {
        client.close()
    }

    func isThisMac(_ device: DeviceInfo) -> Bool {
        device.address.description.filter(\.isHexDigit) == Self.hostAddress
    }

    func displayName(of device: DeviceInfo) -> String {
        isThisMac(device) ? "this Mac" : device.name
    }

    // MARK: - Actions

    func selectMode(_ index: UInt8) {
        let previous = currentMode
        currentMode = index
        Task {
            do {
                let reply = try await send(Request.setMode(index, announce: host?.announceModeChanges ?? true),
                                           failing: "switch mode")
                if let idx = reply.payload.first { currentMode = idx }
            } catch {
                currentMode = previous
            }
        }
    }

    func setANC(_ level: ANCLevel) {
        let previous = anc
        anc = ANCState(level: level, supported: anc?.supported ?? [])
        Task {
            do { try await send(Request.setANC(level), failing: "change noise cancelling") } catch { anc = previous }
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

    // Pickers show the new value at once and go back if the write fails.

    func setSidetone(_ level: SidetoneLevel) {
        let previous = sidetone
        sidetone = SidetoneState(level: level, supported: sidetone?.supported ?? [])
        Task {
            do { try await send(Request.setSidetone(level), failing: "change self voice") } catch { sidetone = previous }
        }
    }

    func setActionButton(_ action: ButtonAction) {
        let previous = actionButton
        actionButton = ActionButtonState(action: action, supported: actionButton?.supported ?? [])
        Task {
            do { try await send(Request.setActionButton(action), failing: "change the Action button") } catch {
                actionButton = previous
            }
        }
    }

    func setAutoOff(minutes: Int) {
        guard let value = UInt8(exactly: minutes) else { return }
        let previous = autoOff
        autoOff = minutes
        Task {
            do { try await send(Request.setAutoOff(minutes: value), failing: "change auto-off") } catch { autoOff = previous }
        }
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
        let action = Self.describe(change, displayName(of: device))
        pendingDevices[address] = change
        pendingTimeouts[address]?.cancel()
        pendingTimeouts[address] = Task { [weak self] in
            do {
                try await self?.send(request, failing: action)
            } catch {
                self?.pendingDevices[address] = nil
                return
            }
            try? await Task.sleep(for: .seconds(20))
            // Closed meanwhile (e.g. connecting another device dropped this Mac): nothing to report.
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.pendingTimeouts[address] = nil
            if self.pendingDevices.removeValue(forKey: address) != nil {
                self.host?.session(self, couldNot: action, because: BMAPError.timeout(request.address))
                await self.loadDevices()
            }
        }
    }

    private static func describe(_ change: PendingChange, _ name: String) -> String {
        "\(change == .connect ? "connect" : "disconnect") \(name)"
    }

    func refreshDevices() {
        guard profile.supports(.pairedDevices) else { return }
        Task { await loadDevices() }
    }

    func refresh() {
        Task { await reload() }
    }

    /// Settings can change on the headphones or from the phone, so the popover catches up
    /// when it opens; not more than every few seconds, so quick open/close doesn't flood
    /// the headphones. The device list is cheap and changes most, so it always reloads.
    func refreshOnOpen(minimumInterval: Duration = .seconds(10)) {
        guard isLoaded, !isClosed else { return }
        if let lastReload, .now - lastReload < minimumInterval {
            refreshDevices()
        } else {
            refresh()
        }
    }

    // MARK: - Device I/O

    @discardableResult
    private func send(_ packet: Packet, failing action: String) async throws -> Packet {
        do {
            let reply = try await client.send(packet)
            apply(reply)
            return reply
        } catch {
            host?.session(self, couldNot: action, because: error)
            throw error
        }
    }

    private func apply(_ p: Packet) {
        if p.address.fblock == Address.pairedDevices.fblock { handleDeviceEvent(p) }
        guard p.op == .status || p.op == .result else { return }
        switch p.address {
        case .battery:
            battery = Decode.battery(p.payload)
            if host?.lowBatteryAlerts == true, let battery {
                batteryAlerts.update(battery: battery, deviceName: displayName)
            }
        case .productName: name = Decode.productName(p.payload)
        case .firmware: firmware = Decode.string(p.payload)
        case .modelName: model = Decode.string(p.payload)
        case .eq: eq = Decode.eq(p.payload)
        case .autoPause: autoPause = Decode.bool(p.payload)
        case .autoAnswer: autoAnswer = Decode.bool(p.payload)
        case .multipoint: multipoint = Decode.multipoint(p.payload)
        case .ancLevel: if let state = Decode.anc(p.payload) { anc = state }
        case .sidetone: if let state = Decode.sidetone(p.payload) { sidetone = state }
        case .actionButton: if let state = Decode.actionButton(p.payload) { actionButton = state }
        case .autoOff: autoOff = Decode.autoOff(p.payload)
        case .voicePrompts: voicePrompts = Decode.voicePrompts(p.payload)
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
            host?.session(self, couldNot: Self.describe(change, name ?? "the device"),
                          because: BMAPError.device(p.address, code))
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
        guard profile.supports(.pairedDevices), !isClosed,
              let reply = try? await client.send(Request.get(.pairedDevices)),
              let paired = Decode.pairedDevices(reply.payload) else { return }
        var loaded: [DeviceInfo] = []
        for address in paired.addresses {
            if let reply = try? await client.send(Request.deviceInfo(address)),
               let info = Decode.deviceInfo(reply.payload) {
                loaded.append(info)
            }
        }
        if !isClosed { devices = loaded }
    }

    /// Reads every setting the profile lists. Some models never answer a request
    /// they don't support, so nothing outside the profile is asked.
    func reload() async {
        lastReload = .now
        var failures: [Error] = []
        for address in profile.settingAddresses {
            guard !isClosed else { return }
            do {
                apply(try await client.send(Request.get(address)))
            } catch {
                log.error("refresh \(address, privacy: .public): \(String(describing: error), privacy: .public)")
                failures.append(error)
            }
        }
        if let first = failures.first {
            host?.session(self, couldNot: failures.count == 1 ? "read a setting" : "read \(failures.count) settings",
                          because: first)
        }
        if let layout = modeLayout {
            // Presets then custom slots; the device errors past the last slot.
            // Collected first so the list appears in one step.
            var slots: [ModeSlot] = []
            for index in layout.slots {
                guard let reply = try? await client.send(Request.get(.modeConfig, [index])),
                      let slot = Decode.modeSlot(reply.payload) else { break }
                if !slot.isEmpty { slots.append(slot) }
            }
            if !isClosed { modes = slots }
        }
        await loadDevices()
        if !isClosed { isLoaded = true }
    }

    private func didClose() {
        guard !isClosed else { return }
        log.info("disconnected \(self.address, privacy: .public)")
        isClosed = true
        pollTask?.cancel()
        deviceRefreshTask?.cancel()
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingTimeouts = [:]
        pendingDevices = [:]
        host?.sessionDidClose(self)
    }
}
