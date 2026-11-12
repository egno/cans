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
    private(set) var serial: String?
    private(set) var model: String?
    private(set) var battery: Int?
    /// Play time left, on models that report it.
    private(set) var batteryMinutes: Int?
    private(set) var modes: [ModeSlot] = []
    /// Every slot as a full record, unused ones included, by index. Empty on models
    /// without `.customModes`.
    private(set) var modeConfigs: [ModeConfig] = []
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
    private(set) var immersiveAudio: ImmersiveAudio?
    /// Power on in the last mode used.
    private(set) var rememberMode: Bool?
    /// The modes the headphones' button cycles through.
    private(set) var favorites: Favorites?
    private(set) var audioSource: AudioSource?
    /// Nil unless the source reports a title.
    private(set) var nowPlaying: NowPlaying?
    /// Asked to turn off; the link dropping is then expected.
    private(set) var isPoweringOff = false
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
    @ObservationIgnored private var nowPlayingRefreshTask: Task<Void, Never>?
    /// Waits for connect/disconnect results that never came; cancelled on close.
    @ObservationIgnored private var pendingTimeouts: [DeviceAddress: Task<Void, Never>] = [:]
    /// Set once the channel is gone; a closed session is never kept by the manager.
    @ObservationIgnored private(set) var isClosed = false
    @ObservationIgnored private var lastReload: ContinuousClock.Instant?
    @ObservationIgnored private var isReloading = false
    /// Writes the headphones have answered or refused, so a script can wait for its own (Scripting.swift).
    @ObservationIgnored private(set) var completedWrites = 0

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
                // Each mode carries its own immersive setting.
                if profile.supports(.immersiveAudio) { await read(.immersiveAudio) }
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

    /// Writes back the button and press the device reported; nothing to do before it's read.
    func setActionButton(_ action: ButtonAction) {
        guard let previous = actionButton else { return }
        actionButton = previous.with(action: action)
        let request = Request.setActionButton(action, button: previous.buttonID, event: previous.event)
        Task {
            do { try await send(request, failing: "change the \(previous.buttonName)") } catch {
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

    // MARK: Modes

    func modeConfig(at index: UInt8) -> ModeConfig? {
        modeConfigs.first { $0.index == index }
    }

    /// Only the user's own slots; the built-in modes refuse writes.
    func canEdit(_ config: ModeConfig) -> Bool {
        profile.supports(.customModes) && config.userConfigurable
    }

    /// The first unused slot a new mode can go in.
    var emptyModeSlot: ModeConfig? {
        modeConfigs.first { $0.isEmpty && canEdit($0) }
    }

    func isFavorite(_ index: UInt8) -> Bool {
        favorites?.contains(index) ?? modeConfig(at: index)?.isFavorite ?? false
    }

    func setImmersiveAudio(_ mode: ImmersiveAudio) {
        guard profile.supports(.immersiveAudio) else { return }
        let previous = immersiveAudio
        immersiveAudio = mode
        Task {
            do { try await send(Request.setImmersiveAudio(mode), failing: "change immersive audio") } catch {
                immersiveAudio = previous
            }
        }
    }

    func setRememberMode(_ on: Bool) {
        guard profile.supports(.rememberMode) else { return }
        let previous = rememberMode
        rememberMode = on
        Task {
            do { try await send(Request.setRememberMode(on), failing: "change which mode the headphones start in") } catch {
                rememberMode = previous
            }
        }
    }

    /// Nothing to do before the set has been read: a write carries all of it.
    func setFavorite(_ index: UInt8, _ on: Bool) {
        guard profile.supports(.favorites), let previous = favorites else { return }
        let wanted = previous.setting(index, favorite: on)
        guard wanted != previous else { return }
        favorites = wanted
        Task {
            do { try await send(Request.setFavorites(wanted), failing: "change the favourite modes") } catch {
                favorites = previous
            }
        }
    }

    /// Creates a mode in an unused slot or changes one of the user's. True once the
    /// headphones took it; the slot is then read again, since that is what they kept.
    func saveMode(_ edit: ModeEdit) async -> Bool {
        guard let config = modeConfig(at: edit.index), canEdit(config) else { return false }
        do {
            // The reply isn't applied: only a fresh read is known to be in the read format.
            try await send(Request.setModeConfig(edit), failing: config.isEmpty ? "create the mode" : "change the mode",
                           applying: false)
        } catch {
            return false
        }
        await reloadMode(edit.index)
        return true
    }

    /// Puts a custom slot back to unused. The headphones keep no copy.
    func deleteMode(_ index: UInt8) async -> Bool {
        guard let config = modeConfig(at: index), canEdit(config), !config.isEmpty else { return false }
        do {
            try await send(Request.resetMode(index), failing: "delete the mode", applying: false)
        } catch {
            return false
        }
        await reloadMode(index)
        if currentMode == index {
            // The headphones move to another mode on their own; ask which.
            currentMode = nil
            await read(.currentMode)
        }
        return true
    }

    private func reloadMode(_ index: UInt8) async {
        await read(.modeConfig, [index])
        if profile.supports(.favorites) { await read(.favorites) }
    }

    // MARK: Rarely changed

    /// Only in the format written on hardware, and once the reading has every part a write carries.
    var canChangeVoicePrompts: Bool {
        profile.supports(.voicePrompts) && profile.voicePromptsFormat == .flagsAndBatteryAnnouncement
            && voicePrompts?.batteryAnnouncement != nil
    }

    func setVoicePrompts(isOn: Bool? = nil, language: UInt8? = nil, batteryAnnouncement: Bool? = nil) {
        guard canChangeVoicePrompts, let previous = voicePrompts else { return }
        let wanted = previous.with(isOn: isOn, language: language, batteryAnnouncement: batteryAnnouncement)
        guard wanted != previous,
              let request = Request.setVoicePrompts(wanted, format: profile.voicePromptsFormat) else { return }
        voicePrompts = wanted
        Task {
            do {
                // A reply shorter than the read would lose the battery announcement; read it instead.
                try await send(request, failing: "change voice prompts", applying: false)
                await read(.voicePrompts)
            } catch {
                voicePrompts = previous
            }
        }
    }

    /// True once the headphones took the name, which is cut to what they can hold.
    func rename(to newName: String) async -> Bool {
        guard profile.supports(.rename), let request = Request.setProductName(newName) else { return false }
        do {
            // Written bare, read with a leading flag byte: the reply could be either.
            try await send(request, failing: "rename the headphones", applying: false)
        } catch {
            return false
        }
        if await !read(.productName) { name = Decode.string(request.payload) }
        return true
    }

    /// Turns the headphones off. They may answer, or just go: the link dropping is the
    /// success, and only an error reply or a link that stays up is a failure.
    func powerOff(dropWithin limit: Duration = .seconds(5)) {
        guard profile.supports(.powerOff), !isPoweringOff, !isClosed else { return }
        isPoweringOff = true
        Task {
            defer { completedWrites += 1 }
            let action = "turn off the headphones"
            var unanswered: Error?
            do {
                _ = try await client.send(Request.powerOff())
            } catch BMAPError.disconnected {
                return
            } catch BMAPError.timeout(let address) {
                unanswered = BMAPError.timeout(address)
            } catch {
                isPoweringOff = false
                host?.session(self, couldNot: action, because: error)
                return
            }
            let deadline = ContinuousClock.now + limit
            while !isClosed, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !isClosed else { return }
            isPoweringOff = false
            if let unanswered { host?.session(self, couldNot: action, because: unanswered) }
        }
    }

    func enterPairingMode() {
        guard profile.supports(.pairingMode) else { return }
        Task { try? await send(Request.setPairingMode(true), failing: Self.pairingAction) }
    }

    private static let pairingAction = "start pairing mode"

    // MARK: Devices

    /// The paired device the headphones are playing from.
    var playingDevice: DeviceInfo? {
        guard audioSource?.kind == .bluetooth, let address = audioSource?.device else { return nil }
        return devices.first { $0.address == address }
    }

    /// With two devices connected, the one that isn't playing: where audio can be moved to.
    var audioRouteTarget: DeviceInfo? {
        guard profile.supports(.audioRouting) else { return nil }
        let connected = devices.filter(\.isConnected)
        guard connected.count == 2, let current = playingDevice ?? connected.first(where: \.isActive) else { return nil }
        return connected.first { $0.address != current.address }
    }

    func routeAudio(to device: DeviceInfo) {
        guard profile.supports(.audioRouting) else { return }
        Task {
            do {
                try await send(Request.routeAudio(to: device.address), failing: "switch audio to \(displayName(of: device))")
                scheduleDeviceRefresh()
            } catch {}
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
                // The link going down mid-request is what connecting another device can do.
                try await self?.send(request, failing: action, quietIfClosed: true)
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
    /// A failed read here only gets logged: the popover already shows the last values,
    /// and a banner for a background catch-up would be noise.
    func refreshOnOpen(minimumInterval: Duration = .seconds(10)) {
        guard isLoaded, !isClosed, !isReloading else { return }
        if let lastReload, .now - lastReload < minimumInterval {
            Task {
                await loadDevices()
                await loadPlayback()
            }
        } else {
            Task { await reload(reportingFailures: false) }
        }
    }

    // MARK: - Device I/O

    /// `applying: false` for writes whose reply may not be in the read format.
    @discardableResult
    private func send(_ packet: Packet, failing action: String, applying: Bool = true,
                      quietIfClosed: Bool = false) async throws -> Packet {
        defer { completedWrites += 1 }
        do {
            let reply = try await client.send(packet)
            if applying { apply(reply) }
            return reply
        } catch {
            if !(quietIfClosed && isClosed) { host?.session(self, couldNot: action, because: error) }
            throw error
        }
    }

    /// A quiet read of one value; false when the headphones didn't give it.
    @discardableResult
    private func read(_ address: Address, _ payload: [UInt8] = []) async -> Bool {
        guard !isClosed, let reply = try? await client.send(Request.get(address, payload)) else { return false }
        apply(reply)
        return true
    }

    /// A [31.6] record as the slot the list shows and, where the model sends full records, its settings.
    private func decodeMode(_ payload: [UInt8]) -> (slot: ModeSlot, config: ModeConfig?, isEmpty: Bool)? {
        if profile.supports(.customModes), let config = Decode.modeConfig(payload) {
            return (config.slot, config, config.isEmpty)
        }
        return Decode.modeSlot(payload).map { ($0, nil, $0.isEmpty) }
    }

    private func apply(_ p: Packet) {
        if p.address.fblock == Address.pairedDevices.fblock { handleDeviceEvent(p) }
        guard p.op == .status || p.op == .result else { return }
        switch p.address {
        case .battery:
            battery = Decode.battery(p.payload)
            batteryMinutes = Decode.batteryReadings(p.payload).first?.minutesRemaining
            if host?.lowBatteryAlerts == true, let battery {
                batteryAlerts.update(battery: battery, deviceName: displayName)
            }
        case .productName: name = Decode.productName(p.payload)
        case .firmware: firmware = Decode.string(p.payload)
        case .serialNumber: serial = Decode.string(p.payload)
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
            guard let mode = decodeMode(p.payload) else { return }
            modes.removeAll { $0.index == mode.slot.index }
            modeConfigs.removeAll { $0.index == mode.slot.index }
            if let config = mode.config {
                modeConfigs.append(config)
                modeConfigs.sort { $0.index < $1.index }
            }
            if !mode.isEmpty {
                modes.append(mode.slot)
                modes.sort { $0.index < $1.index }
            }
        case .immersiveAudio: if let mode = Decode.immersiveAudio(p.payload) { immersiveAudio = mode }
        case .rememberMode: if let on = Decode.bool(p.payload) { rememberMode = on }
        case .favorites: if let set = Decode.favorites(p.payload) { favorites = set }
        case .audioSource:
            guard let source = Decode.audioSource(p.payload), source != audioSource else { return }
            audioSource = source
            // Another device took over: what's playing changed with it. A reload reads it anyway.
            if !isReloading { scheduleNowPlayingRefresh() }
        // Outside a listing, a record means the track changed.
        case .nowPlaying: if p.op == .status { scheduleNowPlayingRefresh() }
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
        case (.pairingMode, .error), (.audioRouting, .error):
            // Refused after a PROCESSING that had already answered the request.
            let code = p.payload.first.flatMap(DeviceErrorCode.init(rawValue:))
            host?.session(self, couldNot: p.address == .pairingMode ? Self.pairingAction : "switch audio",
                          because: BMAPError.device(p.address, code))
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
            await loadPlayback()
        }
    }

    private func scheduleNowPlayingRefresh() {
        guard profile.supports(.nowPlaying) else { return }
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadNowPlaying()
        }
    }

    /// Which device is playing and what. Read when the popover opens and when the
    /// headphones report a change, never on a timer.
    private func loadPlayback() async {
        if profile.supports(.audioSource) { await read(.audioSource) }
        await loadNowPlaying()
    }

    /// With nothing playing the headphones answer with an error, no records, or track
    /// numbers under a placeholder title; without a title there's nothing to show.
    private func loadNowPlaying() async {
        guard profile.supports(.nowPlaying), !isClosed else { return }
        let listed = (try? await client.enumerate(Request.nowPlaying())).map(Decode.nowPlaying)
        if !isClosed { nowPlaying = listed.flatMap { $0.title == nil ? nil : $0 } }
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
    func reload(reportingFailures: Bool = true) async {
        // One at a time; a second would only repeat the same requests.
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
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
        if reportingFailures, let first = failures.first {
            host?.session(self, couldNot: failures.count == 1 ? "read a setting" : "read \(failures.count) settings",
                          because: first)
        }
        if let layout = modeLayout {
            // Presets then custom slots; the device errors past the last slot.
            // Collected first so the list appears in one step.
            var slots: [ModeSlot] = []
            var configs: [ModeConfig] = []
            for index in layout.slots {
                guard let reply = try? await client.send(Request.get(.modeConfig, [index])),
                      let mode = decodeMode(reply.payload) else { break }
                if let config = mode.config { configs.append(config) }
                if !mode.isEmpty { slots.append(mode.slot) }
            }
            if !isClosed {
                modes = slots
                modeConfigs = configs
            }
        }
        await loadDevices()
        await loadNowPlaying()
        if !isClosed { isLoaded = true }
    }

    private func didClose() {
        guard !isClosed else { return }
        log.info("disconnected \(self.address, privacy: .public)")
        isClosed = true
        pollTask?.cancel()
        deviceRefreshTask?.cancel()
        nowPlayingRefreshTask?.cancel()
        pendingTimeouts.values.forEach { $0.cancel() }
        pendingTimeouts = [:]
        pendingDevices = [:]
        host?.sessionDidClose(self)
    }
}
