import AppKit
import BMAP
import IOBluetooth
import Observation
import os

private let log = Logger(subsystem: "io.github.egno.cans", category: "headphones")

/// Finds and connects every pair of Bose headphones in reach, one `HeadphoneSession`
/// each, and holds the app-wide settings and the error banner.
///
/// Holding a BMAP channel doesn't affect audio, so all reachable pairs are
/// connected, not just the one the popover shows.
@MainActor @Observable
final class HeadphonesManager: SessionHost {
    enum Status: Equatable {
        case searching
        case connected
        case unavailable
    }

    /// A pair that has talked BMAP to Cans before but isn't connected now.
    struct AbsentPair: Identifiable, Equatable {
        let address: String
        let name: String
        var id: String { address }
    }

    /// Connected headphones, in the order they connected.
    private(set) var sessions: [HeadphoneSession] = []
    /// Paired headphones without a session, for the picker.
    private(set) var absentPairs: [AbsentPair] = []
    /// Absent pairs the user asked to connect, while that's in progress.
    private(set) var connectingPairs: Set<String> = []
    private(set) var lastError: String?
    /// Searching or unavailable; `status` reports connected whenever there's a session.
    private var searchState: Status = .searching

    var status: Status { sessions.isEmpty ? searchState : .connected }

    private var selectedAddress: String? {
        didSet { UserDefaults.standard.set(selectedAddress, forKey: Keys.selected) }
    }

    /// The pair the popover and menu bar show.
    var selected: HeadphoneSession? {
        Self.selection(in: sessions.map(\.address), preferred: selectedAddress).flatMap(session(for:))
    }

    /// The user's pick when it's connected, otherwise the first pair to connect. Only `select`
    /// changes the pick, so the preferred pair takes over again when it comes back.
    static func selection(in connected: [String], preferred: String?) -> String? {
        connected.first { $0 == preferred } ?? connected.first
    }

    func select(_ session: HeadphoneSession) {
        selectedAddress = session.address
        // Its device list may be stale; the popover is open, so catch up.
        session.refreshDevices()
    }

    var lowBatterySessions: [HeadphoneSession] { sessions.filter(\.isBatteryLow) }

    // MARK: - Mac audio

    /// The Mac's audio outputs. Separate from the BMAP link: a pair can be connected to
    /// Cans without being connected to this Mac for audio, and the other way round.
    let audio = AudioOutput()

    /// The Mac's default output is this pair.
    func isPlayingHere(_ session: HeadphoneSession) -> Bool {
        audio.device(forBluetoothAddress: session.address).map(audio.isDefault) ?? false
    }

    /// The pair has an audio device on this Mac to switch to.
    func canPlayHere(_ session: HeadphoneSession) -> Bool {
        audio.device(forBluetoothAddress: session.address) != nil
    }

    func playHere(_ session: HeadphoneSession) {
        do {
            guard let device = audio.device(forBluetoothAddress: session.address) else {
                throw AudioOutputError.notConnected
            }
            try audio.makeDefault(device)
        } catch {
            log.error("couldn't switch audio to \(session.address, privacy: .public): \(String(describing: error), privacy: .public)")
            showError("Couldn't switch audio to \(session.displayName): \(error.localizedDescription)")
        }
    }

    /// Remove the menu bar item while no headphones are connected.
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
            if lowBatteryAlerts { BatteryAlerts.requestAuthorization() }
        }
    }

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var isShuttingDown = false
    /// An event asked for a pass while one was running; run another after the wait.
    @ObservationIgnored private var rescanRequested = false
    /// Wait between passes: none after a success or a wake, then 5 s doubling to 60 s.
    @ObservationIgnored private var backoff: Duration = .zero
    @ObservationIgnored private var lastPass: ContinuousClock.Instant?
    /// The device being probed right now.
    @ObservationIgnored private var probing: String?
    /// When each device was last probed. Our own probe may bring up a link that macOS
    /// reports as a connect, so those don't reset the backoff.
    @ObservationIgnored private var lastProbed: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var observers = Observers()
    @ObservationIgnored private let sdpQuery = SDPQuery()
    @ObservationIgnored private let linkOpener = LinkOpener()
    /// Kept across reconnects, so a pair that drops and comes back doesn't notify again.
    @ObservationIgnored private var batteryAlerts: [String: BatteryAlerts] = [:]
    @ObservationIgnored private var errorDismissTask: Task<Void, Never>?
    @ObservationIgnored private var isPopoverOpen = false
    /// Addresses that have answered BMAP before; these are worth retrying.
    @ObservationIgnored private var knownAddresses: Set<String> {
        didSet { UserDefaults.standard.set(Array(knownAddresses).sorted(), forKey: Keys.known) }
    }

    private enum Keys {
        static let selected = "selectedHeadphones"
        static let known = "knownHeadphones"
        /// Before several pairs: the last pair connected.
        static let legacyAddress = "lastDeviceAddress"
        static let announce = "announceModeChanges"
        static let hide = "hideWhenDisconnected"
        static let lowBatteryAlerts = "lowBatteryAlerts"
    }

    init() {
        let defaults = UserDefaults.standard
        var known = Set(defaults.stringArray(forKey: Keys.known) ?? [])
        if let legacy = defaults.string(forKey: Keys.legacyAddress) {
            if defaults.string(forKey: Keys.selected) == nil { defaults.set(legacy, forKey: Keys.selected) }
            known.insert(legacy)
            defaults.set(Array(known).sorted(), forKey: Keys.known)
            defaults.removeObject(forKey: Keys.legacyAddress)
        }
        knownAddresses = known
        selectedAddress = defaults.string(forKey: Keys.selected)
        announceModeChanges = defaults.object(forKey: Keys.announce) as? Bool ?? true
        hideWhenDisconnected = defaults.bool(forKey: Keys.hide)
        lowBatteryAlerts = defaults.object(forKey: Keys.lowBatteryAlerts) as? Bool ?? true
        if lowBatteryAlerts { BatteryAlerts.requestAuthorization() }
        observers.install { [weak self] event in self?.handle(event) }
        // Local list, no radio: lets the first popover name known pairs before any pass ends.
        updateAbsentPairs()
        requestPass()
    }

    // MARK: - Errors

    /// For problems outside the headphones, such as launch at login.
    func showProblem(_ message: String) {
        showError(message)
    }

    func dismissError() {
        errorDismissTask?.cancel()
        lastError = nil
    }

    func session(_ session: HeadphoneSession, couldNot action: String, because error: Error) {
        log.error("\(session.address, privacy: .public) couldn't \(action, privacy: .public): \(String(describing: error), privacy: .public)")
        // Name the pair only when there's more than one it could be.
        showError(Self.message(action: action, error: error, pair: sessions.count > 1 ? session.displayName : nil))
    }

    /// "Couldn't <action>[ on <pair>]: <reason>"
    static func message(action: String, error: Error, pair: String?) -> String {
        "Couldn't \(action)\(pair.map { " on \($0)" } ?? ""): \(reason(for: error))"
    }

    /// Shows the message in the popover. It goes after a few seconds of being on screen,
    /// so one that comes up while the popover is closed waits to be seen.
    private func showError(_ message: String) {
        lastError = message
        scheduleErrorDismiss()
    }

    private func scheduleErrorDismiss() {
        errorDismissTask?.cancel()
        guard isPopoverOpen, lastError != nil else { return }
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    // MARK: - Popover

    /// Both may be called more than once per open or close.
    func popoverDidOpen() {
        guard !isPopoverOpen else { return }
        isPopoverOpen = true
        scheduleErrorDismiss()
        selected?.refreshOnOpen()
    }

    func popoverDidClose() {
        guard isPopoverOpen else { return }
        isPopoverOpen = false
        errorDismissTask?.cancel()
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

    /// Asks macOS to bring up the pair's Bluetooth link, then probes it at once.
    func connect(_ pair: AbsentPair) {
        guard !connectingPairs.contains(pair.address), session(for: pair.address) == nil,
              let device = IOBluetoothDevice(addressString: pair.address) else { return }
        connectingPairs.insert(pair.address)
        Task {
            defer { connectingPairs.remove(pair.address) }
            guard await linkOpener.open(device) else {
                showError("Couldn't connect \(pair.name): not in reach")
                return
            }
            let found = await withRadio {
                guard session(for: pair.address) == nil, !isShuttingDown else { return true }
                probing = pair.address
                defer {
                    probing = nil
                    lastProbed[pair.address] = .now
                }
                return await probe(device, address: pair.address)
            }
            // Events that came in meanwhile were queued behind the radio.
            if rescanRequested { requestPass() }
            if !found { showError("Couldn't connect \(pair.name): the headphones didn't answer") }
        }
    }

    /// One probe at a time: the loop and a user's Connect share the radio.
    private func withRadio<T>(_ body: () async -> T) async -> T {
        while isConnecting { try? await Task.sleep(for: .milliseconds(200)) }
        isConnecting = true
        defer { isConnecting = false }
        return await body()
    }

    /// Skips the backoff wait and looks for headphones now.
    func retryNow() {
        guard !isConnecting else { return }
        searchState = .searching
        backoff = .zero
        requestPass()
    }

    private func handle(_ event: Observers.Event) {
        switch event {
        case .woke:
            backoff = .zero
            requestPass()
        case .connected(let device):
            guard let address = device.addressString, session(for: address) == nil, probing != address,
                  isCandidate(device) else { return }
            let probedRecently = lastProbed[address].map { .now - $0 < .seconds(60) } ?? false
            Task {
                // Give the headphones a moment to bring up their services.
                try? await Task.sleep(for: .seconds(2))
                guard session(for: address) == nil, probing != address else { return }
                // A device we just probed may only be reporting our own link: keep the backoff.
                if !probedRecently { backoff = .zero }
                requestPass()
            }
        }
    }

    /// Runs a pass once the backoff allows, or queues one if a pass is running.
    /// Events never skip the wait, so they can't make the loop spin.
    private func requestPass() {
        guard !isShuttingDown else { return }
        rescanRequested = true
        guard !isConnecting else { return }
        connectTask?.cancel()
        connectTask = Task { await connectLoop() }
    }

    /// Polls while no pair is connected. With one connected, the others are found through
    /// connect and wake events instead, so idle devices aren't paged in the background.
    private func connectLoop() async {
        while !Task.isCancelled {
            if let lastPass {
                let wait = lastPass + backoff - .now
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled else { return }
            }
            // Background retries keep showing "Not connected" instead of flickering to "Connecting…".
            if searchState != .unavailable { searchState = .searching }
            rescanRequested = false
            let found = await connectToCandidates()
            // Cancelled while waiting for the radio: the pass that replaces this one counts.
            guard !Task.isCancelled else { return }
            lastPass = .now
            backoff = found ? .zero : backoff == .zero ? .seconds(5) : min(backoff * 2, .seconds(60))
            if sessions.isEmpty { searchState = .unavailable }
            guard sessions.isEmpty || rescanRequested else { return }
        }
    }

    /// Probes each candidate that has no session yet. True if one connected.
    private func connectToCandidates() async -> Bool {
        await withRadio { await probeCandidates() }
    }

    private func probeCandidates() async -> Bool {
        var found = false
        for device in candidates() {
            guard !Task.isCancelled, !isShuttingDown else { break }
            guard let address = device.addressString, session(for: address) == nil else { continue }
            probing = address
            found = await probe(device, address: address) || found
            probing = nil
            lastProbed[address] = .now
        }
        updateAbsentPairs()
        return found
    }

    private func probe(_ device: IOBluetoothDevice, address: String) async -> Bool {
        for channel in await BMAPService.channels(for: device, query: sdpQuery) {
            let transport = RFCOMMTransport(device: device, channel: channel)
            do {
                try await transport.open()
                let client = BMAPClient(transport: transport)
                // Other clients send this first as a hello; ignore the answer.
                _ = try? await client.send(Request.get(.bmapVersion))
                let reply = try await client.send(Request.get(.productID))   // confirms it speaks BMAP
                let profile = Decode.productID(reply.payload)
                    .map { ModelRegistry.profile(forProductID: $0, name: device.name) }
                    ?? .generic(name: device.name)
                let session = HeadphoneSession(client: client, profile: profile, address: address, host: self,
                                               batteryAlerts: alerts(for: address))
                guard add(session) else { throw BMAPError.disconnected }
                log.info("connected to \(address, privacy: .public) on channel \(channel): \(profile.id, privacy: .public)")
                return true
            } catch {
                log.info("candidate \(address, privacy: .public) channel \(channel) failed: \(String(describing: error), privacy: .public)")
                transport.close()
            }
        }
        return false
    }

    /// Paired audio devices: the selected pair first, then ones that look like Bose.
    /// `isConnected()` is unreliable on current macOS, so candidates are probed by
    /// opening the BMAP channel.
    private func candidates() -> [IOBluetoothDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter(isCandidate)
        var seen = Set<String>()
        let unique = paired.filter { seen.insert($0.addressString ?? "").inserted }
        let first = unique.filter { $0.addressString == selectedAddress }
        let rest = unique.filter { $0.addressString != selectedAddress }
        return first + rest.filter(looksLikeBose) + rest.filter { !looksLikeBose($0) }
    }

    /// Any audio device while nothing is connected (the way Cans found headphones before
    /// it knew vendors); once a pair is connected, only ones that look like Bose.
    private func isCandidate(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == kBluetoothDeviceClassMajorAudio && (sessions.isEmpty || looksLikeBose(device))
    }

    /// Talked BMAP before, or says Bose in its Device ID record or name.
    private func looksLikeBose(_ device: IOBluetoothDevice) -> Bool {
        if let address = device.addressString, knownAddresses.contains(address) { return true }
        if BMAPService.vendorID(of: device) == BMAPService.boseVendorID { return true }
        return device.name?.localizedCaseInsensitiveContains("bose") ?? false
    }

    /// Only pairs that have actually spoken BMAP, so a Bose speaker doesn't show up as headphones.
    private func updateAbsentPairs() {
        var seen = Set<String>()
        absentPairs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { device in
            guard let address = device.addressString, knownAddresses.contains(address),
                  session(for: address) == nil, seen.insert(address).inserted else { return nil }
            return AbsentPair(address: address, name: device.name ?? address)
        }
    }

    private func session(for address: String) -> HeadphoneSession? {
        sessions.first { $0.address == address }
    }

    private func alerts(for address: String) -> BatteryAlerts {
        if let existing = batteryAlerts[address] { return existing }
        let alerts = BatteryAlerts(identifier: address)
        batteryAlerts[address] = alerts
        return alerts
    }

    /// False when the session can't be kept: its channel already closed, or the app is quitting.
    private func add(_ session: HeadphoneSession) -> Bool {
        guard !session.isClosed, !isShuttingDown else {
            session.close()
            return false
        }
        if sessions.isEmpty {
            revealed = false
            lastError = nil
        }
        sessions.append(session)
        knownAddresses.insert(session.address)
        absentPairs.removeAll { $0.address == session.address }
        session.start()
        return true
    }

    func sessionDidClose(_ session: HeadphoneSession) {
        sessions.removeAll { $0 === session }
        if sessions.isEmpty { searchState = .unavailable }
        guard !isShuttingDown else { return }
        updateAbsentPairs()
        requestPass()
    }

    func shutdown() {
        isShuttingDown = true
        connectTask?.cancel()
        sessions.forEach { $0.close() }
    }
}

/// System events that are good moments to look for headphones.
@MainActor
private final class Observers: NSObject {
    enum Event {
        case connected(IOBluetoothDevice)
        case woke
    }

    private var handler: ((Event) -> Void)?
    private var btNotification: IOBluetoothUserNotification?

    func install(_ handler: @escaping (Event) -> Void) {
        self.handler = handler
        btNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                    selector: #selector(deviceConnected(_:device:)))
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Passed on at once, so the manager can tell a probe's own link from a new device.
    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        handler?(.connected(device))
    }

    @objc private func didWake() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.handler?(.woke)
        }
    }
}
