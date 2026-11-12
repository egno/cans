import BMAP
import Foundation
import Testing
@testable import Cans

/// A QC Ultra gen 1 with every setting answering. Payloads are captures from fw 1.6.7
/// where there is one (see BMAPTests), otherwise in the documented layout.
@MainActor
private func ultra() -> FakeDevice {
    let d = FakeDevice()
    d.replies = [
        .productName: [0] + Array("Atom".utf8),
        .modelName: Array("Bose QC Ultra Headphones".utf8),
        .firmware: Array("1.6.7".utf8),
        .serialNumber: Array("081234Z51234567AE".utf8),
        .battery: [0x32, 0xff, 0xff, 0x00],
        .eq: [0xf6, 0x0a, 0x00, 0x00, 0xf6, 0x0a, 0x00, 0x01, 0xf6, 0x0a, 0x00, 0x02],
        .autoPause: [1],
        .autoAnswer: [0],
        .multipoint: [0x07],
        .currentMode: [0],
        .sidetone: [0x01, 0x03, 0x0f],
        .actionButton: [0x80, 0x09, 0x13, 0x00, 0x09, 0x40, 0x0a],
        .autoOff: [0x3c],
        .voicePrompts: [0xe1, 0x00, 0x01, 0x81, 0x5e, 0x01, 0x01],
        .audioSource: [0x00, 0x0f, 0x00],
        .immersiveAudio: [0],
        .rememberMode: [0],
        .favorites: [0x0a, 0x00, 0x1f],
        .pairedDevices: [0x00],
    ]
    d.slots = [0: "Quiet", 1: "Aware", 2: "Immersion", 3: "None", 4: "Commute", 5: "None"]
    return d
}

@MainActor
private func loaded(_ device: FakeDevice, _ host: FakeHost) async -> HeadphoneSession {
    let session = HeadphoneSession(client: BMAPClient(transport: device), profile: .qcUltra,
                                   address: "00-11-22-33-44-55", host: host,
                                   batteryAlerts: BatteryAlerts(identifier: "test"))
    await session.reload()
    return session
}

@MainActor @Suite struct UltraSessionTests {
    @Test func readsEverySettingWithoutAFailure() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        #expect(host.failures.isEmpty)
        #expect(session.isLoaded)
        #expect(session.firmware == "1.6.7")
        #expect(session.serial == "081234Z51234567AE")
        #expect(session.battery == 50)
        #expect(session.batteryMinutes == nil)   // `ffff`: all a gen 1 has been seen to send
        #expect(session.sidetone?.level == .low)
        #expect(session.autoOff == 60)
        #expect(AutoOff.choices.contains(60))
        #expect(session.immersiveAudio == .off)
        #expect(session.rememberMode == false)
        #expect(session.favorites?.modes == [0, 1, 2, 3, 4])
        #expect(session.audioSource?.kind == AudioSource.Kind.none)
        #expect(session.nowPlaying == nil)
        #expect(session.voicePrompts?.batteryAnnouncement == true)
        #expect(session.canChangeVoicePrompts)
        #expect(controlsSummary(session) == "Self voice low · Off after 1 hour")
    }

    @Test func batteryMinutesShowWhenTheHeadphonesReportThem() async {
        let device = ultra()
        device.replies[.battery] = [0x5a, 0x04, 0xb0, 0x00]
        let session = await loaded(device, FakeHost())
        #expect(session.battery == 90)
        #expect(session.batteryMinutes == 1200)
        #expect(playTimeLabel(minutes: 1200) == "20 h")
        #expect(playTimeLabel(minutes: 320) == "5 h 20 min")
        #expect(playTimeLabel(minutes: 45) == "45 min")
    }

    // MARK: Modes

    @Test func modesCarryTheirDetails() async throws {
        let device = ultra()
        device.records[4] = FakeDevice.modeRecord(index: 4, name: "Commute", prompt: 7, favorite: true,
                                                  cncLevel: 3, spatial: 1, windBlock: false)
        let session = await loaded(device, FakeHost())

        #expect(session.modes.map(\.name) == ["Quiet", "Aware", "Immersion", "Commute"])
        #expect(session.modeConfigs.map(\.index) == [0, 1, 2, 3, 4, 5])
        let commute = try #require(session.modeConfig(at: 4))
        #expect(commute.cncLevel == 3 && commute.spatial == .still && commute.windBlock == false)
        #expect(commute.promptName == "Commute")
        #expect(session.canEdit(commute))
        // Built-in modes are never offered for editing.
        for index: UInt8 in 0...2 {
            #expect(!session.canEdit(try #require(session.modeConfig(at: index))))
        }
        #expect(session.emptyModeSlot?.index == 3)
    }

    @Test func createsEditsAndDeletesACustomMode() async throws {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)
        let slot = try #require(session.emptyModeSlot)

        // Create, in the first unused slot.
        var edit = ModeEdit(index: slot.index, name: "Desk", cncLevel: 4, spatial: .still)
        #expect(await session.saveMode(edit))
        #expect(device.written.contains(Request.setModeConfig(edit)))
        // The slot is read again after the write, then the favourites.
        #expect(device.written.suffix(2).map(\.address) == [.modeConfig, .favorites])
        #expect(device.written.suffix(2).first == Request.get(.modeConfig, [slot.index]))
        #expect(session.modes.map(\.name) == ["Quiet", "Aware", "Immersion", "Desk", "Commute"])
        #expect(session.modeConfig(at: slot.index)?.cncLevel == 4)
        #expect(session.modeConfig(at: slot.index)?.spatial == .still)
        #expect(session.emptyModeSlot?.index == 5)

        // Edit: built from the settings as read, in the write's own 39-byte shape.
        edit = ModeEdit(editing: try #require(session.modeConfig(at: slot.index)))
        edit.name = "Desk 2"
        edit.windBlock = true
        #expect(await session.saveMode(edit))
        let write = try #require(device.written.last { $0.op == .setGet && $0.address == .modeConfig })
        #expect(write.payload.count == 39)
        #expect(write.payload == edit.payload)
        #expect(session.modeConfig(at: slot.index)?.name == "Desk 2")
        #expect(session.modeConfig(at: slot.index)?.windBlock == true)
        #expect(session.modeConfig(at: slot.index)?.cncLevel == 0)   // wind block forces full cancelling

        // Delete: the slot goes back to unused and leaves the list.
        #expect(await session.deleteMode(slot.index))
        #expect(device.written.contains(Request.resetMode(slot.index)))
        #expect(session.modes.map(\.name) == ["Quiet", "Aware", "Immersion", "Commute"])
        #expect(session.emptyModeSlot?.index == slot.index)
        #expect(host.failures.isEmpty)
    }

    @Test func builtInModesAreNeverWritten() async throws {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)
        let before = device.written.count

        #expect(!(await session.saveMode(ModeEdit(editing: try #require(session.modeConfig(at: 1))))))
        #expect(!(await session.deleteMode(0)))
        #expect(!(await session.deleteMode(3)))    // unused: nothing to delete
        #expect(!(await session.deleteMode(9)))    // not a slot the headphones listed
        #expect(device.written.count == before)
        #expect(host.failures.isEmpty)
    }

    @Test func aRefusedModeWriteIsReportedAndChangesNothing() async throws {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)
        device.failWrites = true

        #expect(!(await session.saveMode(ModeEdit(index: 3, name: "Desk"))))
        #expect(!(await session.deleteMode(4)))
        #expect(host.failures == ["create the mode", "delete the mode"])
        #expect(session.modes.map(\.name) == ["Quiet", "Aware", "Immersion", "Commute"])
    }

    @Test func deletingTheCurrentModeAsksWhichModeIsOnNow() async {
        let device = ultra()
        device.replies[.currentMode] = [4]
        let session = await loaded(device, FakeHost())
        #expect(session.currentMode == 4)

        device.replies[.currentMode] = [0]
        #expect(await session.deleteMode(4))
        #expect(session.currentMode == 0)
        #expect(session.noiseControlSummary == "Quiet mode")
    }

    @Test func modeNamesAreCheckedAndCutToWhatFits() async {
        let session = await loaded(ultra(), FakeHost())
        #expect(modeNameProblem("Desk", index: 3, in: session) == nil)
        #expect(modeNameProblem("  ", index: 3, in: session) != nil)
        #expect(modeNameProblem("none", index: 3, in: session) != nil)
        #expect(modeNameProblem("commute", index: 3, in: session) != nil)
        #expect(modeNameProblem("Commute", index: 4, in: session) == nil)   // its own name

        #expect(NameLimit.fitting("Desk", bytes: 31) == "Desk")
        #expect(NameLimit.fitting(String(repeating: "a", count: 40), bytes: ModeEdit.maxNameBytes).count == 31)
        // Never half a character: 15 two-byte letters fit, the 16th doesn't.
        #expect(NameLimit.fitting(String(repeating: "é", count: 20), bytes: 31) == String(repeating: "é", count: 15))
    }

    @Test func noiseCancellingReadsTheOtherWayRound() {
        #expect(NoiseCancelling.strength(cncLevel: 0) == 10)
        #expect(NoiseCancelling.strength(cncLevel: 10) == 0)
        #expect(NoiseCancelling.strength(cncLevel: 99) == 0)
        #expect(NoiseCancelling.cncLevel(strength: 7) == 3)
        #expect(NoiseCancelling.cncLevel(strength: 40) == 0)
        #expect(NoiseCancelling.label(strength: 10) == "Full")
        #expect(NoiseCancelling.label(strength: 0) == "Aware")
        #expect(NoiseCancelling.label(strength: 7) == "7 of 10")
    }

    // MARK: Immersive audio, favourites, remember

    @Test func immersiveAudioWritesAndGoesBackWhenRefused() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        session.setImmersiveAudio(.motion)
        #expect(session.immersiveAudio == .motion)   // shown at once
        await eventually { session.completedWrites == 1 }
        #expect(device.written.last == Request.setImmersiveAudio(.motion))
        #expect(session.immersiveAudio == .motion)
        #expect(host.failures.isEmpty)

        device.failWrites = true
        session.setImmersiveAudio(.still)
        #expect(session.immersiveAudio == .still)
        await eventually { session.completedWrites == 2 }
        #expect(session.immersiveAudio == .motion)
        #expect(host.failures == ["change immersive audio"])
    }

    @Test func switchingModeReadsItsImmersiveSetting() async {
        let device = ultra()
        let session = await loaded(device, FakeHost())
        device.replies[.immersiveAudio] = [2]   // Immersion turns it on
        session.selectMode(2)
        await eventually { session.immersiveAudio == .motion }
        #expect(session.immersiveAudio == .motion)
        #expect(session.currentMode == 2)
    }

    @Test func favouritesWriteTheWholeSetAndGoBackWhenRefused() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)
        #expect(session.isFavorite(4) && !session.isFavorite(5))

        session.setFavorite(4, false)
        #expect(!session.isFavorite(4))   // shown at once
        await eventually { session.completedWrites == 1 }
        // Modes 0-3 of 10: `0a 00 0f`.
        #expect(device.written.last == Packet(.favorites, .setGet, [0x0a, 0x00, 0x0f]))
        #expect(session.favorites?.modes == [0, 1, 2, 3])

        session.setFavorite(3, false)
        await eventually { session.completedWrites == 2 }
        #expect(session.favorites?.modes == [0, 1, 2])
        let writes = device.written.count
        session.setFavorite(2, true)    // already a favourite: nothing to send
        #expect(device.written.count == writes)

        device.failWrites = true
        session.setFavorite(0, false)
        #expect(!session.isFavorite(0))
        await eventually { session.completedWrites == 3 }
        #expect(session.isFavorite(0))
        #expect(host.failures == ["change the favourite modes"])
    }

    @Test func rememberModeTogglesAndGoesBackWhenRefused() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        session.setRememberMode(true)
        await eventually { session.completedWrites == 1 }
        #expect(device.written.last == Request.setRememberMode(true))
        #expect(session.rememberMode == true)

        device.failWrites = true
        session.setRememberMode(false)
        #expect(session.rememberMode == false)
        await eventually { session.completedWrites == 2 }
        #expect(session.rememberMode == true)
        #expect(host.failures.count == 1)
    }

    // MARK: Voice prompts, name

    @Test func voicePromptsWriteTwoBytesAndKeepTheUnexplainedBits() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        // Off: byte 0 loses the on bit only; the battery announcement goes along as read.
        session.setVoicePrompts(isOn: false)
        await eventually { session.completedWrites == 1 }
        #expect(device.written.contains(Packet(.voicePrompts, .setGet, [0xc1, 0x01])))
        #expect(device.written.last == Request.get(.voicePrompts))   // read back in full
        #expect(session.voicePrompts?.isOn == false)
        #expect(session.voicePrompts?.batteryAnnouncement == true)

        session.setVoicePrompts(isOn: true, language: 2)
        await eventually { session.completedWrites == 2 }
        #expect(device.written.contains(Packet(.voicePrompts, .setGet, [0xe2, 0x01])))
        #expect(session.voicePrompts?.languageName == "French")

        session.setVoicePrompts(batteryAnnouncement: false)
        await eventually { session.completedWrites == 3 }
        #expect(device.written.contains(Packet(.voicePrompts, .setGet, [0xe2, 0x00])))
        #expect(session.voicePrompts?.batteryAnnouncement == false)
        #expect(host.failures.isEmpty)

        device.failWrites = true
        session.setVoicePrompts(isOn: false)
        #expect(session.voicePrompts?.isOn == false)
        await eventually { session.completedWrites == 4 }
        #expect(session.voicePrompts?.isOn == true)
        #expect(host.failures == ["change voice prompts"])
    }

    @Test func qc35VoicePromptsStayReadOnly() async {
        let device = FakeDevice()
        device.replies = [.voicePrompts: [0xa1, 0x00, 0x04, 0xcf, 0xde], .pairedDevices: [0x00]]
        let session = HeadphoneSession(client: BMAPClient(transport: device), profile: .qc35II,
                                       address: "00-11-22-33-44-55", host: FakeHost(),
                                       batteryAlerts: BatteryAlerts(identifier: "test"))
        await session.reload(reportingFailures: false)
        #expect(session.voicePrompts?.isOn == true)
        #expect(!session.canChangeVoicePrompts)
        let before = device.written.count
        session.setVoicePrompts(isOn: false)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(device.written.count == before)
        #expect(session.voicePrompts?.isOn == true)
        // Nor any of the QC Ultra's extras.
        #expect(!(await session.rename(to: "Other")))
        session.powerOff()
        session.enterPairingMode()
        session.setImmersiveAudio(.still)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(device.written.count == before)
    }

    @Test func renameShowsTheNameTheHeadphonesKept() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        #expect(await session.rename(to: "  Desk Cans "))
        #expect(device.written.contains(Packet(.productName, .setGet, Array("Desk Cans".utf8))))
        #expect(session.displayName == "Desk Cans")

        // Nothing to write.
        let before = device.written.count
        #expect(!(await session.rename(to: "   ")))
        #expect(device.written.count == before)

        device.failWrites = true
        #expect(!(await session.rename(to: "Other")))
        #expect(session.displayName == "Desk Cans")
        #expect(host.failures == ["rename the headphones"])
    }

    @Test func renameFallsBackToWhatWasWrittenWhenTheReadFails() async {
        let device = ultra()
        let session = await loaded(device, FakeHost())
        // Too long: cut to 31 bytes on a character, like the write.
        let long = String(repeating: "é", count: 20)
        device.silent = [.productName]
        async let renamed = session.rename(to: long)
        // The write goes unanswered here, so answer it by hand and leave the read to time out.
        await eventually { device.written.last?.op == .setGet }
        device.onReceive?(Packet(.productName, .status, []).bytes)
        #expect(await renamed)
        #expect(session.displayName == String(repeating: "é", count: 15))
    }

    // MARK: Readouts

    @Test func audioSourceNamesThePlayingDevice() async throws {
        let device = ultra()
        let mac: [UInt8] = [0xbc, 0x89, 0xc1, 0x59, 0x5b, 0xfb], phone: [UInt8] = [0x40, 0xfa, 0xfe, 0x3b, 0xd7, 0x8f]
        device.replies[.pairedDevices] = [0x03] + mac + phone
        device.replies[.audioSource] = [0x00, 0x0f, 0x01] + phone
        device.deviceInfos = [0xfb: mac + [0x01, 2, 3] + Array("Laptop".utf8),
                              0x8f: phone + [0x03, 2, 3] + Array("Phone".utf8)]
        let session = await loaded(device, FakeHost())

        #expect(session.audioSource?.kind == .bluetooth)
        #expect(session.playingDevice?.name == "Phone")
    }

    @Test func routingOffersTheConnectedDeviceThatIsNotPlaying() async throws {
        func info(_ last: UInt8, _ name: String, _ status: UInt8) -> [UInt8] {
            [0x40, 0xfa, 0xfe, 0x3b, 0xd7, last, status, 2, 3] + Array(name.utf8)
        }
        let device = ultra()
        device.replies[.pairedDevices] = [0x03, 0x40, 0xfa, 0xfe, 0x3b, 0xd7, 1, 0x40, 0xfa, 0xfe, 0x3b, 0xd7, 2,
                                          0x40, 0xfa, 0xfe, 0x3b, 0xd7, 3]
        device.deviceInfos = [1: info(1, "Laptop", 0x03), 2: info(2, "Phone", 0x01), 3: info(3, "Tablet", 0x00)]
        let host = FakeHost()
        let session = await loaded(device, host)
        #expect(session.devices.map(\.name) == ["Laptop", "Phone", "Tablet"])

        // Laptop is active, so the phone is where audio can go.
        let target = try #require(session.audioRouteTarget)
        #expect(target.name == "Phone")
        session.routeAudio(to: target)
        await eventually { session.completedWrites == 1 }
        #expect(device.written.contains(Request.routeAudio(to: target.address)))
        #expect(host.failures.isEmpty)

        // Refused, as a model that hasn't the function would.
        device.failWrites = true
        session.routeAudio(to: target)
        await eventually { session.completedWrites == 2 }
        #expect(host.failures == ["switch audio to Phone"])

        // One connected device: nowhere to move it.
        device.deviceInfos[2] = info(2, "Phone", 0x00)
        device.replies[.pairedDevices]?[0] = 0x01
        session.refreshDevices()
        await eventually { session.devices.filter(\.isConnected).count == 1 }
        #expect(session.audioRouteTarget == nil)
    }

    @Test func nowPlayingIsListedAndEmptyMeansNone() async {
        let device = ultra()
        device.nowPlaying = [0: "Blue in Green", 3: "3", 4: "5", 6: "0"]
        let session = await loaded(device, FakeHost())
        #expect(session.nowPlaying?.title == "Blue in Green")
        #expect(session.nowPlaying.flatMap(trackLabel) == "Track 3 of 5")
        // One listing per reload, not a poll.
        #expect(device.written.filter { $0.address == .nowPlaying }.count == 1)

        // Idle, as captured: a placeholder title over track numbers.
        device.nowPlaying = [0: "Not Provided", 3: "1", 4: "1", 6: "0"]
        await session.reload()
        #expect(session.nowPlaying == nil)

        device.nowPlaying = nil   // a runtime error, as with nothing attached
        await session.reload()
        #expect(session.nowPlaying == nil)
        #expect(trackLabel(NowPlaying(attributes: [0: "Song"])) == nil)
        #expect(trackLabel(NowPlaying(attributes: [3: "2"])) == "Track 2")
    }

    // MARK: Actions

    @Test func powerOffExpectsTheLinkToDrop() async {
        let device = ultra(), host = FakeHost()
        device.dropsOnPowerOff = true
        let session = await loaded(device, host)

        session.powerOff()
        #expect(session.isPoweringOff)
        await eventually { session.completedWrites == 1 }
        #expect(device.written.last == Request.powerOff())
        #expect(session.isClosed)
        #expect(host.closed == 1)
        #expect(host.failures.isEmpty)
    }

    @Test func powerOffAnsweredThenDroppedIsNotAFailure() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        session.powerOff()
        await eventually { device.written.last == Request.powerOff() }
        try? await Task.sleep(for: .milliseconds(20))
        device.onClose?()
        await eventually { session.completedWrites == 1 }
        #expect(host.failures.isEmpty)
        #expect(session.isClosed)
    }

    @Test func powerOffRefusedIsReported() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)
        device.failWrites = true

        session.powerOff()
        await eventually { session.completedWrites == 1 }
        #expect(host.failures == ["turn off the headphones"])
        #expect(!session.isPoweringOff)
        #expect(!session.isClosed)
    }

    @Test func powerOffAnsweredButStillOnStopsWaitingQuietly() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        session.powerOff(dropWithin: .milliseconds(100))
        #expect(session.isPoweringOff)
        await eventually { session.completedWrites == 1 }
        #expect(!session.isPoweringOff)
        #expect(host.failures.isEmpty)
    }

    @Test func pairingModeReportsARefusal() async {
        let device = ultra(), host = FakeHost()
        let session = await loaded(device, host)

        session.enterPairingMode()
        await eventually { session.completedWrites == 1 }
        #expect(device.written.contains(Request.setPairingMode(true)))
        #expect(host.failures.isEmpty)

        device.failWrites = true
        session.enterPairingMode()
        await eventually { session.completedWrites == 2 }
        #expect(host.failures == ["start pairing mode"])
    }
}

// MARK: - Scripting

@Suite struct UltraScriptingTests {
    @Test func parsesImmersiveAndPowerOff() throws {
        #expect(try ScriptParser.parse(["immersive", "Still"]) == ScriptRequest(command: .immersive(.still)))
        #expect(try ScriptParser.parse(["immersive", "off", "--headset", "Atom"])
            == ScriptRequest(command: .immersive(.off), headset: "Atom"))
        #expect(try ScriptParser.parse(["power-off"]) == ScriptRequest(command: .powerOff))
        for bad in [["immersive"], ["immersive", "loud"], ["power-off", "now"]] {
            #expect(throws: ScriptError.self) { try ScriptParser.parse(bad) }
        }
        #expect(ScriptParser.isCommandLine(["immersive", "motion"]))
        #expect(ScriptParser.isCommandLine(["power-off"]))
        let url = try #require(URL(string: "cans://immersive/motion"))
        #expect(try ScriptParser.parse(try #require(ScriptParser.arguments(from: url))).command == .immersive(.motion))
    }

    @Test func statusCarriesTheNewReadouts() {
        var status = HeadsetStatus(
            name: "Atom", model: "QC Ultra", address: "00-11-22-33-44-55", selected: false, battery: 90,
            mode: "Quiet", modes: ["Quiet", "Aware"], playingMacAudio: false, equalizer: nil,
            devices: [.init(name: "Phone", connected: true, active: true, thisMac: false, playing: true)])
        status.firmware = "1.6.7"
        status.serialNumber = "0812"
        status.batteryMinutesRemaining = 320
        status.immersiveAudio = "still"
        status.favoriteModes = ["Quiet"]
        status.rememberMode = true
        status.nowPlaying = .init(title: "Blue in Green", trackNumber: 3, totalTracks: 5)
        #expect(status.text == """
            Atom
              model: QC Ultra
              battery: 90%, about 5 h 20 min left
              mode: Quiet
              modes: Quiet, Aware
              immersive audio: still
              mac audio: no
              devices: Phone (playing)
              now playing: Blue in Green
              firmware: 1.6.7
              serial number: 0812
            """)
        let json = HeadsetStatus.json([status])
        for field in ["\"immersiveAudio\" : \"still\"", "\"batteryMinutesRemaining\" : 320", "\"serialNumber\" : \"0812\"",
                      "\"rememberMode\" : true", "\"title\" : \"Blue in Green\"", "\"playing\" : true", "\"favoriteModes\""] {
            #expect(json.contains(field), "status --json should have \(field)")
        }
    }
}
