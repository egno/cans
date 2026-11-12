import BMAP
import Testing
@testable import Cans

// MARK: - Fakes

/// Answers GETs from a table, like a device that knows only those addresses.
@MainActor
final class FakeDevice: BMAPTransport {
    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?
    var written: [Packet] = []
    var replies: [Address: [UInt8]] = [:]
    /// Mode slots by index; past the last one the device answers with an error.
    var slots: [UInt8: String] = [:]
    var failWrites = false

    func write(_ bytes: [UInt8]) throws {
        var stream = PacketStream()
        guard let packet = stream.append(bytes).first else { return }
        written.append(packet)
        let reply: Packet
        switch packet.op {
        case .get where packet.address == .modeConfig:
            let index = packet.payload.first ?? 0
            if let name = slots[index] {
                let nameBytes = Array(name.utf8) + [UInt8](repeating: 0, count: 32 - name.utf8.count)
                reply = Packet(.modeConfig, .status, [index, 0, 0, 0, 0, 0] + nameBytes)
            } else {
                reply = Packet(.modeConfig, .error, [DeviceErrorCode.invalidData.rawValue])
            }
        case .get:
            if let payload = replies[packet.address] {
                reply = Packet(packet.address, .status, payload)
            } else {
                reply = Packet(packet.address, .error, [DeviceErrorCode.functionNotSupported.rawValue])
            }
        default:
            reply = failWrites
                ? Packet(packet.address, .error, [DeviceErrorCode.invalidData.rawValue])
                : Packet(packet.address, .status, packet.payload)
        }
        Task { @MainActor in self.onReceive?(reply.bytes) }
    }

    func close() {}

    var requested: Set<Address> { Set(written.map(\.address)) }
}

@MainActor
final class FakeHost: SessionHost {
    var announceModeChanges = true
    var lowBatteryAlerts = false
    var failures: [String] = []
    var closed = 0

    func session(_ session: HeadphoneSession, couldNot action: String, because error: Error) {
        failures.append(action)
    }

    func sessionDidClose(_ session: HeadphoneSession) { closed += 1 }
}

@MainActor
private func makeSession(_ profile: ModelProfile, _ device: FakeDevice, _ host: FakeHost) -> HeadphoneSession {
    HeadphoneSession(client: BMAPClient(transport: device), profile: profile, address: "00-11-22-33-44-55",
                     host: host, batteryAlerts: BatteryAlerts(identifier: "test"))
}

// MARK: - Sessions

@MainActor @Suite struct SessionTests {
    /// Captured from a QC35 II on fw 4.8.1.
    private func qc35() -> FakeDevice {
        let d = FakeDevice()
        d.replies = [
            .productName: [0] + Array("High Note".utf8),
            .firmware: Array("4.8.1".utf8),
            .battery: [80],
            .ancLevel: [0x01, 0x0b],
            .sidetone: [0x01, 0x00, 0x0f],
            .actionButton: [0x10, 0x04, 0x02, 0x07],
            .autoOff: [0x14],
            .voicePrompts: [0xa1, 0x00, 0x04, 0xcf, 0xde],
            .pairedDevices: [0x00],
        ]
        return d
    }

    @Test func qc35ReadsOnlyWhatItSupports() async {
        let device = qc35(), host = FakeHost()
        let session = makeSession(.qc35II, device, host)
        await session.reload()

        for address in [Address.eq, .modeConfig, .currentMode, .multipoint, .autoPause, .autoAnswer, .modelName] {
            #expect(!device.requested.contains(address), "QC35 II must not be asked for \(address)")
        }
        #expect(host.failures.isEmpty)
        #expect(session.isLoaded)
        #expect(session.displayName == "High Note")
        #expect(session.modelName == "QuietComfort 35 II")
        #expect(session.anc == ANCState(level: .high, supported: [.off, .low, .high]))
        #expect(session.noiseControlSummary == "Noise cancelling high")
        #expect(session.modeLayout == nil)
        #expect(session.hasControls)
        #expect(session.autoOff == 20)
        #expect(session.voicePrompts.map(voicePromptsLabel) == "On · US English")
    }

    @Test func qcUltraReadsModesUntilTheLastSlot() async {
        let device = FakeDevice(), host = FakeHost()
        device.replies = [.productName: [0] + Array("Atom".utf8), .battery: [55], .currentMode: [1],
                          .eq: [0xf6, 0x0a, 0x00, 0x00], .pairedDevices: [0x00]]
        device.slots = [0: "Quiet", 1: "Aware", 2: "Immersion", 3: "None", 4: "Commute"]
        let session = makeSession(.qcUltra, device, host)
        await session.reload()

        #expect(session.modes.map(\.name) == ["Quiet", "Aware", "Immersion", "Commute"])
        #expect(session.noiseControlSummary == "Aware mode")
        #expect(!device.requested.contains(.ancLevel))
        #expect(device.requested.contains(.eq))
        #expect(session.hasControls)   // the announce-mode-changes switch
        // Firmware, model name and the toggles have no reply in the table.
        #expect(host.failures == ["read 5 settings"])
    }

    @Test func failedWriteRevertsTheTile() async throws {
        let device = qc35(), host = FakeHost()
        let session = makeSession(.qc35II, device, host)
        await session.reload()

        device.failWrites = true
        session.setANC(.off)
        #expect(session.anc?.level == .off)   // shown at once
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.anc?.level == .high)
        #expect(host.failures == ["change noise cancelling"])
        #expect(device.written.last == Request.setANC(.off))
    }

    @Test func closeCancelsPendingDeviceChanges() async throws {
        let device = FakeDevice(), host = FakeHost()
        let session = makeSession(.qcUltra, device, host)
        // A phone the headphones know, not connected.
        let phone = try #require(Decode.deviceInfo([0x40, 0xfa, 0xfe, 0x3b, 0xd7, 0x8f, 0, 2, 3] + Array("Phone".utf8)))
        session.connect(phone)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.pendingDevices[phone.address] == .connect)
        // Connecting the phone dropped this Mac, and with it the channel.
        device.onClose?()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.pendingDevices.isEmpty)
        #expect(host.failures.isEmpty)
    }

    @Test func alreadyClosedClientMakesAClosedSession() async throws {
        let device = FakeDevice(), host = FakeHost()
        let client = BMAPClient(transport: device)
        client.close()
        let session = HeadphoneSession(client: client, profile: .qcUltra, address: "00-11-22-33-44-55",
                                       host: host, batteryAlerts: BatteryAlerts(identifier: "test"))
        #expect(session.isClosed)
        session.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.written.isEmpty)
    }

    @Test func controlsSummaryPicksTwoValuesTheModelHas() async {
        let qc35Session = makeSession(.qc35II, qc35(), FakeHost())
        await qc35Session.reload()
        #expect(controlsSummary(qc35Session) == "Self voice off · Off after 20 min")

        let ultra = FakeDevice()
        ultra.replies = [.autoPause: [1], .autoAnswer: [0], .pairedDevices: [0x00]]
        let ultraSession = makeSession(.qcUltra, ultra, FakeHost())
        await ultraSession.reload()
        #expect(controlsSummary(ultraSession) == "Auto-pause on · Auto-answer off")
        // Modes bring the announce switch, so Controls shows even before the toggles load.
        #expect(makeSession(.qcUltra, FakeDevice(), FakeHost()).hasControls)
        #expect(!makeSession(.generic(), FakeDevice(), FakeHost()).hasControls)
    }

    @Test func openingThePopoverRefreshesAtMostEveryFewSeconds() async throws {
        let device = qc35()
        let session = makeSession(.qc35II, device, FakeHost())
        await session.reload()
        device.written = []

        // Just loaded: only the device list.
        session.refreshOnOpen()
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.requested == [.pairedDevices])

        device.written = []
        session.refreshOnOpen(minimumInterval: .zero)
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.requested.isSuperset(of: Set(ModelProfile.qc35II.settingAddresses)))
        #expect(!device.requested.contains(.eq))
    }

    @Test func closeIsReportedOnce() {
        let device = FakeDevice(), host = FakeHost()
        let session = makeSession(.generic(), device, host)
        device.onClose?()
        device.onClose?()
        #expect(host.closed == 1)
        #expect(!session.isLoaded)
    }
}

// MARK: - Presentation

@MainActor @Suite struct PresentationTests {
    @Test func errorNamesThePairOnlyWhenThereAreSeveral() {
        #expect(HeadphonesManager.message(action: "switch mode", error: BMAPError.timeout(.currentMode), pair: nil)
                == "Couldn't switch mode: headphones didn't respond")
        #expect(HeadphonesManager.message(action: "change auto-off", error: BMAPError.device(.autoOff, .invalidData),
                                          pair: "High Note")
                == "Couldn't change auto-off on High Note: headphones reported an error")
    }

    @Test func menuBarLowBatteryDescription() {
        #expect(LowBatteryText.description(shown: "Atom", percent: 15, low: [("Atom", 15)]) == "Atom battery low, 15%")
        #expect(LowBatteryText.description(shown: "Atom", percent: 80, low: [("High Note", 12)])
                == "Atom 80%; High Note battery low, 12%")
    }

    @Test func selectionPrefersThePickUntilItLeaves() {
        #expect(HeadphonesManager.selection(in: ["atom", "note"], preferred: "note") == "note")
        // The pick isn't connected: show the first pair, but the pick is kept for when it's back.
        #expect(HeadphonesManager.selection(in: ["atom"], preferred: "note") == "atom")
        #expect(HeadphonesManager.selection(in: ["atom", "note"], preferred: nil) == "atom")
        #expect(HeadphonesManager.selection(in: [], preferred: "note") == nil)
    }

    @Test func ancSymbolsAreDistinct() {
        let symbols = ANCLevel.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(Set(ANCLevel.allCases.map(\.summary)).count == ANCLevel.allCases.count)
    }

    @Test func autoOffLabels() {
        #expect(AutoOff.choices.map { autoOffLabel(minutes: Int($0)) }
                == ["Never", "5 min", "20 min", "40 min", "1 hour", "3 hours"])
        #expect(autoOffLabel(minutes: 90) == "90 min")
    }
}

// MARK: - Mac audio

@MainActor @Suite struct AudioOutputTests {
    @Test func addressFromUID() {
        #expect(AudioOutput.bluetoothAddress(fromUID: "2C-41-A1-4D-B8-EB:output") == "2c41a14db8eb")
        #expect(AudioOutput.bluetoothAddress(fromUID: "2C-41-A1-4D-B8-EB") == "2c41a14db8eb")
        #expect(AudioOutput.bluetoothAddress(fromUID: "BuiltInSpeakerDevice") == nil)
        #expect(AudioOutput.bluetoothAddress(fromUID: "AppleUSBAudioEngine:Apple Inc.:Studio Display:1:2") == nil)
        // A display's UID, all hex and dashes but 32 digits.
        #expect(AudioOutput.bluetoothAddress(fromUID: "1E6D0777-0000-0000-061F-0104B53C2278") == nil)
        // Hex-only but not an address.
        #expect(AudioOutput.bluetoothAddress(fromUID: "BEEF:output") == nil)
        #expect(AudioOutput.normalized("2c-41-a1-4d-b8-eb") == AudioOutput.normalized("2C:41:A1:4D:B8:EB"))
    }

    @Test func matchesOnlyBluetoothOutputsOfThatPair() {
        let speakers = AudioOutput.Device(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Speakers", isBluetooth: false)
        // Same-looking UID but over another transport.
        let impostor = AudioOutput.Device(id: 2, uid: "2C-41-A1-4D-B8-EB:output", name: "Virtual", isBluetooth: false)
        let note = AudioOutput.Device(id: 3, uid: "2C-41-A1-4D-B8-EB:output", name: "High Note", isBluetooth: true)
        let atom = AudioOutput.Device(id: 4, uid: "BC-87-FA-00-11-22:output", name: "Atom", isBluetooth: true)
        let all = [speakers, impostor, note, atom]
        #expect(AudioOutput.device(forBluetoothAddress: "2c-41-a1-4d-b8-eb", in: all) == note)
        #expect(AudioOutput.device(forBluetoothAddress: "bc-87-fa-00-11-22", in: all) == atom)
        #expect(AudioOutput.device(forBluetoothAddress: "00-11-22-33-44-55", in: all) == nil)
    }
}
