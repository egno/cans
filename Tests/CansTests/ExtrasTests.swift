import BMAP
import Foundation
import Testing
@testable import Cans

@MainActor
private func session(_ profile: ModelProfile, _ device: FakeDevice, _ host: FakeHost) -> HeadphoneSession {
    HeadphoneSession(client: BMAPClient(transport: device), profile: profile, address: "00-11-22-33-44-55",
                     host: host, batteryAlerts: BatteryAlerts(identifier: "test"))
}

/// Preferences that no other test or the app shares.
private func scratchDefaults() -> UserDefaults {
    let name = "cans-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func device(_ last: UInt8, _ name: String, connected: Bool, active: Bool = false) -> DeviceInfo {
    let status: UInt8 = (connected ? 1 : 0) | (active ? 2 : 0)
    return Decode.deviceInfo([0x40, 0xfa, 0xfe, 0x3b, 0xd7, last, status, 2, 3] + Array(name.utf8))!
}

private func bands(bass: Int, mid: Int, treble: Int) -> [EQBand] {
    [EQBand(kind: .bass, range: -10...10, value: bass), EQBand(kind: .mid, range: -10...10, value: mid),
     EQBand(kind: .treble, range: -10...10, value: treble)]
}

// MARK: - Calls

@Suite struct CallDetectorTests {
    private let t0 = ContinuousClock.now

    @Test func aBriefBlipIsNotACall() {
        var detector = CallDetector()
        let deadline = detector.microphone(inUse: true, at: t0)
        #expect(deadline == t0 + detector.startDelay)
        #expect(detector.microphone(inUse: false, at: t0 + .milliseconds(400)) == nil)
        #expect(detector.settle(at: t0 + .seconds(5)) == nil)
        #expect(!detector.isInCall)
    }

    @Test func aCallStartsOnceTheMicrophoneHasStayedInUse() {
        var detector = CallDetector()
        _ = detector.microphone(inUse: true, at: t0)
        #expect(detector.settle(at: t0 + .milliseconds(500)) == nil)
        // Repeated reports don't push the deadline out.
        #expect(detector.microphone(inUse: true, at: t0 + .seconds(1)) == t0 + detector.startDelay)
        #expect(detector.settle(at: t0 + detector.startDelay) == .started)
        #expect(detector.isInCall)
        #expect(detector.settle(at: t0 + .seconds(10)) == nil)
    }

    @Test func aGapInsideACallDoesNotEndIt() {
        var detector = CallDetector()
        _ = detector.microphone(inUse: true, at: t0)
        _ = detector.settle(at: t0 + .seconds(2))
        let t1 = t0 + .seconds(60)
        #expect(detector.microphone(inUse: false, at: t1) == t1 + detector.endDelay)
        #expect(detector.microphone(inUse: true, at: t1 + .seconds(1)) == nil)
        #expect(detector.settle(at: t1 + .seconds(10)) == nil)
        #expect(detector.isInCall)

        let t2 = t1 + .seconds(60)
        _ = detector.microphone(inUse: false, at: t2)
        #expect(detector.settle(at: t2 + .seconds(1)) == nil)
        #expect(detector.settle(at: t2 + detector.endDelay) == .ended)
        #expect(!detector.isInCall)
    }
}

@Suite struct CallModePlanTests {
    @Test func switchesAndPutsBack() {
        var plan = CallModePlan<Int>()
        #expect(plan.callStarted(current: 0, callSetting: 1) == 1)
        plan.settingChanged(to: 1)   // our own switch being reported
        #expect(plan.willRestore)
        #expect(plan.callEnded(current: 1) == 0)
        #expect(!plan.willRestore)
    }

    @Test func alreadyOnTheCallModeDoesNothing() {
        var plan = CallModePlan<Int>()
        #expect(plan.callStarted(current: 1, callSetting: 1) == nil)
        #expect(plan.callEnded(current: 1) == nil)
    }

    @Test func anUnknownModeIsSwitchedButNotPutBack() {
        var plan = CallModePlan<Int>()
        #expect(plan.callStarted(current: nil, callSetting: 1) == 1)
        #expect(!plan.willRestore)
        #expect(plan.callEnded(current: 1) == nil)
    }

    @Test func aChangeDuringTheCallStands() {
        var plan = CallModePlan<Int>()
        _ = plan.callStarted(current: 0, callSetting: 1)
        plan.settingChanged(to: 2)
        #expect(!plan.willRestore)
        // Even if the user comes back to the call mode before hanging up.
        plan.settingChanged(to: 1)
        #expect(plan.callEnded(current: 1) == nil)
    }

    @Test func aFailedSwitchLeavesNothingToPutBack() {
        var plan = CallModePlan<Int>()
        _ = plan.callStarted(current: 0, callSetting: 1)
        plan.settingChanged(to: 0)   // the session reverting its optimistic value
        #expect(plan.callEnded(current: 0) == nil)
    }

    @Test func noiseSettingsSurvivePreferences() {
        for setting in [NoiseSetting.mode(4), .anc(.low), .anc(.off)] {
            #expect(NoiseSetting(stored: setting.stored) == setting)
        }
        #expect(NoiseSetting(stored: "mode") == nil)
        #expect(NoiseSetting(stored: "anc:9") == nil)
    }
}

@MainActor @Suite struct CallModeSessionTests {
    @Test func modesAndLevelsAreBothNoiseOptions() async {
        let ultra = FakeDevice(), host = FakeHost()
        ultra.replies = [.currentMode: [1], .pairedDevices: [0x00]]
        ultra.slots = [0: "Quiet", 1: "Aware"]
        let withModes = session(.qcUltra, ultra, host)
        await withModes.reload(reportingFailures: false)
        #expect(withModes.noiseOptions.map(\.name) == ["Quiet", "Aware"])
        #expect(withModes.currentNoiseSetting == .mode(1))

        let qc35 = FakeDevice()
        qc35.replies = [.ancLevel: [0x01, 0x0b], .pairedDevices: [0x00]]
        let withLevels = session(.qc35II, qc35, host)
        await withLevels.reload(reportingFailures: false)
        #expect(withLevels.noiseOptions.map(\.setting) == [.anc(.off), .anc(.low), .anc(.high)])
        #expect(withLevels.currentNoiseSetting == .anc(.high))
        withLevels.apply(.anc(.low))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(qc35.written.last == Request.setANC(.low))
        #expect(withLevels.completedWrites == 1)
    }

    @Test func theChoiceIsKeptPerPair() async {
        let defaults = scratchDefaults()
        let device = FakeDevice(), host = FakeHost()
        let pair = session(.qcUltra, device, host)
        let calls = CallModeSwitch(defaults: defaults)
        #expect(calls.setting(for: pair) == nil)
        calls.set(.mode(1), for: pair)
        #expect(CallModeSwitch(defaults: defaults).setting(for: pair) == .mode(1))
        calls.set(nil, for: pair)
        #expect(CallModeSwitch(defaults: defaults).choices.isEmpty)
    }
}

// MARK: - This Mac only

@Suite struct ThisMacOnlyTests {
    private let mac = device(1, "MacBook", connected: true, active: true)
    private let phone = device(2, "Phone", connected: true)
    private let tablet = device(3, "Tablet", connected: false)

    private func isMac(_ d: DeviceInfo) -> Bool { d.address == mac.address }

    @Test func dropsEveryOtherConnectedDevice() {
        #expect(ThisMacOnlyPlan.others(in: [mac, phone, tablet], isThisMac: isMac) == [phone])
        #expect(ThisMacOnlyPlan.others(in: [mac, tablet], isThisMac: isMac).isEmpty)
    }

    @Test func dropsNothingWhenThisMacCannotBeTold() {
        #expect(ThisMacOnlyPlan.others(in: [mac, phone], isThisMac: { _ in false }).isEmpty)
    }

    @Test func reconnectsOnlyIntoASpareConnection() {
        let gone = device(2, "Phone", connected: false)
        let dropped = [gone.address.description]
        #expect(ThisMacOnlyPlan.reconnectable(dropped: dropped, in: [mac, gone, tablet], multipoint: true) == [gone])
        #expect(ThisMacOnlyPlan.reconnectable(dropped: dropped, in: [mac, gone, tablet], multipoint: nil) == [gone])
        // Without multipoint it would push this Mac out.
        #expect(ThisMacOnlyPlan.reconnectable(dropped: dropped, in: [mac, gone], multipoint: false).isEmpty)
        // Something else took the place meanwhile.
        let other = device(3, "Tablet", connected: true)
        #expect(ThisMacOnlyPlan.reconnectable(dropped: dropped, in: [mac, gone, other], multipoint: true).isEmpty)
        #expect(ThisMacOnlyPlan.reconnectable(dropped: [], in: [mac, gone], multipoint: true).isEmpty)
    }

    @Test func forgetsDevicesThatCameBackOrWereUnpaired() {
        let gone = device(2, "Phone", connected: false)
        let dropped = [gone.address.description, tablet.address.description]
        #expect(ThisMacOnlyPlan.stillDropped(dropped, in: [mac, gone, tablet]) == dropped)
        #expect(ThisMacOnlyPlan.stillDropped(dropped, in: [mac, phone, tablet]) == [tablet.address.description])
        #expect(ThisMacOnlyPlan.stillDropped(dropped, in: [mac]).isEmpty)
    }

    @Test func namesReadAsAList() {
        #expect(listed(["Phone"]) == "Phone")
        #expect(listed(["Phone", "Tablet"]) == "Phone and Tablet")
        #expect(listed(["Phone", "Tablet", "Watch"]) == "Phone, Tablet and Watch")
    }
}

// MARK: - Equalizer presets

@MainActor @Suite struct EQPresetTests {
    @Test func builtInsStayInRangeAndHaveDistinctNames() {
        for preset in EQPresetStore.builtIn {
            for kind in EQBand.Kind.allCases { #expect(EQPreset.range.contains(preset.value(for: kind))) }
        }
        #expect(Set(EQPresetStore.builtIn.map(\.name)).count == EQPresetStore.builtIn.count)
        #expect(Set(EQPresetStore.builtIn.map(\.id)).count == EQPresetStore.builtIn.count)
        #expect(EQPreset(name: "Loud", bass: 40, mid: -40, treble: 3).summary == "bass +10, mid −10, treble +3")
    }

    @Test func showsWhichPresetTheEqualizerIsOn() {
        let store = EQPresetStore(defaults: scratchDefaults())
        #expect(store.match(bands(bass: 0, mid: 0, treble: 0))?.name == "Flat")
        #expect(store.match(bands(bass: 6, mid: 0, treble: 0))?.name == "Bass boost")
        #expect(store.match(bands(bass: 5, mid: 0, treble: 0)) == nil)
        #expect(store.match([]) == nil)
        store.save(name: "Mine", bands: bands(bass: 5, mid: 0, treble: 0))
        #expect(store.match(bands(bass: 5, mid: 0, treble: 0))?.name == "Mine")
    }

    @Test func savesRenamesAndDeletes() throws {
        let defaults = scratchDefaults()
        let store = EQPresetStore(defaults: defaults)
        let mine = try #require(store.save(name: "  Mine ", bands: bands(bass: 2, mid: -1, treble: 4)))
        #expect(mine.name == "Mine")
        #expect(store.save(name: "flat", bands: bands(bass: 1, mid: 1, treble: 1)) == nil)
        #expect(store.save(name: "  ", bands: bands(bass: 1, mid: 1, treble: 1)) == nil)

        // Saving under the same name updates it.
        let again = try #require(store.save(name: "mine", bands: bands(bass: 3, mid: 0, treble: 0)))
        #expect(again.id == mine.id)
        #expect(store.custom.count == 1)
        #expect(store.custom[0].bass == 3)

        store.save(name: "Other", bands: bands(bass: 0, mid: 1, treble: 0))
        #expect(!store.rename(mine.id, to: "Other"))
        #expect(!store.rename(mine.id, to: "Vocal"))
        #expect(!store.rename("builtin.flat", to: "Level"))
        #expect(store.rename(mine.id, to: "MINE"))   // its own name, recased
        #expect(store.rename(mine.id, to: "Evening"))
        #expect(store.preset(named: "evening")?.id == mine.id)

        // Kept across launches.
        #expect(EQPresetStore(defaults: defaults).custom == store.custom)
        store.delete(mine.id)
        #expect(EQPresetStore(defaults: defaults).custom.map(\.name) == ["Other"])
        #expect(store.all.count == EQPresetStore.builtIn.count + 1)
    }

    @Test func applyingWritesOnlyTheBandsThatDiffer() async throws {
        let device = FakeDevice(), host = FakeHost()
        device.replies = [.eq: [0xf6, 0x0a, 0x00, 0x00, 0xf6, 0x0a, 0x00, 0x01, 0xf6, 0x0a, 0x04, 0x02],
                          .pairedDevices: [0x00]]
        let pair = session(.qcUltra, device, host)
        await pair.reload(reportingFailures: false)
        let before = device.written.count

        let boost = try #require(EQPresetStore.builtIn.first { $0.name == "Bass boost" })
        #expect(!boost.matches(pair.eq))
        #expect(pair.apply(boost) == 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Array(device.written.dropFirst(before)) == [Request.setEQ(.bass, value: 6), Request.setEQ(.treble, value: 0)])
        #expect(pair.completedWrites == 2)
    }

    @Test func aNarrowerBandCapsThePreset() {
        let narrow = EQBand(kind: .bass, range: -4...4, value: 4)
        let boost = EQPreset(name: "Boost", bass: 6, mid: 0, treble: 0)
        #expect(boost.value(for: narrow) == 4)
        #expect(boost.matches([narrow]))
    }
}

// MARK: - Scripting

@Suite struct ScriptingTests {
    @Test func parsesCommands() throws {
        #expect(try ScriptParser.parse(["status"]) == ScriptRequest(command: .status(json: false)))
        #expect(try ScriptParser.parse(["status", "--json"]) == ScriptRequest(command: .status(json: true)))
        #expect(try ScriptParser.parse(["eq", "Bass", "boost"]) == ScriptRequest(command: .eq("Bass boost")))
        #expect(try ScriptParser.parse(["--headset", "High Note", "mode", "Quiet"])
            == ScriptRequest(command: .mode("Quiet"), headset: "High Note"))
        #expect(try ScriptParser.parse(["mode", "Aware", "--headset=Atom"])
            == ScriptRequest(command: .mode("Aware"), headset: "Atom"))
        #expect(try ScriptParser.parse(["this-mac-only"]) == ScriptRequest(command: .thisMacOnly(.toggle)))
        #expect(try ScriptParser.parse(["this-mac-only", "ON"]) == ScriptRequest(command: .thisMacOnly(.on)))
        #expect(try ScriptParser.parse(["disconnect", "My", "Phone"]) == ScriptRequest(command: .disconnect("My Phone")))
        #expect(try ScriptParser.parse(["connect", "Phone"]) == ScriptRequest(command: .connect("Phone")))
        #expect(try ScriptParser.parse(["mode", "--help"]).command == .help)
    }

    @Test func rejectsWhatItCannotRun() {
        for bad in [[], ["mode"], ["eq"], ["fly"], ["this-mac-only", "maybe"], ["status", "--loud"], ["mode", "Quiet", "--headset"]] {
            #expect(throws: ScriptError.self) { try ScriptParser.parse(bad) }
        }
    }

    @Test func urlsAreTheSameCommands() throws {
        let url = try #require(URL(string: "cans://mode/Quiet?headset=High%20Note"))
        #expect(ScriptParser.arguments(from: url) == ["mode", "Quiet", "--headset", "High Note"])
        let eq = try #require(URL(string: "cans://eq/Bass%20boost"))
        #expect(try ScriptParser.parse(try #require(ScriptParser.arguments(from: eq))) == ScriptRequest(command: .eq("Bass boost")))
        let toggle = try #require(URL(string: "cans://this-mac-only"))
        #expect(ScriptParser.arguments(from: toggle) == ["this-mac-only"])
        let off = try #require(URL(string: "CANS://this-mac-only/off"))
        #expect(ScriptParser.arguments(from: off) == ["this-mac-only", "off"])
        #expect(ScriptParser.arguments(from: try #require(URL(string: "https://mode/Quiet"))) == nil)
    }

    @Test func onlyCommandsMakeItTheCommandLineTool() {
        #expect(ScriptParser.isCommandLine(["status"]))
        #expect(ScriptParser.isCommandLine(["--help"]))
        #expect(!ScriptParser.isCommandLine([]))
        // What launch services and debuggers pass an app.
        #expect(!ScriptParser.isCommandLine(["-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!ScriptParser.isCommandLine(["-psn_0_12345"]))
    }

    @Test func namesMatchLoosely() throws {
        let modes = ["Quiet", "Aware", "Immersion", "Quiet Commute"]
        let find = { (name: String) throws(ScriptError) in try NameMatch.find(name, in: modes, kind: "mode") { $0 } }
        #expect(try find("quiet") == "Quiet")          // exact wins over a longer name
        #expect(try find("imm") == "Immersion")
        #expect(try find("commute") == "Quiet Commute")
        #expect(throws: ScriptError("“qu” fits several modes: Quiet, Quiet Commute")) { try find("qu") }
        #expect(throws: ScriptError("No mode named “loud”; there's Quiet, Aware, Immersion, Quiet Commute")) { try find("loud") }
    }

    @Test func statusReadsAsText() {
        let status = HeadsetStatus(
            name: "Atom", model: "QC Ultra", address: "00-11-22-33-44-55", selected: true, battery: 55,
            mode: "Aware", modes: ["Quiet", "Aware"], playingMacAudio: true,
            equalizer: .init(bass: 6, mid: 0, treble: -2, preset: nil),
            devices: [.init(name: "this Mac", connected: true, active: true, thisMac: true),
                      .init(name: "Phone", connected: true, active: false, thisMac: false),
                      .init(name: "Tablet", connected: false, active: false, thisMac: false)])
        #expect(status.text == """
            Atom (selected)
              model: QC Ultra
              battery: 55%
              mode: Aware
              modes: Quiet, Aware
              mac audio: yes
              equalizer: bass +6, mid 0, treble −2
              devices: this Mac (active), Phone (connected), Tablet
            """)
        #expect(HeadsetStatus.text([]) == "No headphones connected")
        #expect(HeadsetStatus.json([status]).contains("\"battery\" : 55"))
    }
}
