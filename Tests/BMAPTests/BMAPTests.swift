import Testing
@testable import BMAP

private func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map {
        let i = s.index(s.startIndex, offsetBy: $0)
        return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
    }
}

// MARK: - Framing

@Suite struct FramingTests {
    @Test func encodesPacket() {
        #expect(Request.setMode(1, announce: true).bytes == [31, 3, 5, 2, 1, 1])
        #expect(Request.get(.firmware).bytes == [0, 5, 1, 0])
    }

    @Test func reassemblesSplitAndMergedFrames() {
        var s = PacketStream()
        let a = Packet(.battery, .status, [0x32, 0xff, 0xff, 0x00]).bytes
        let b = Packet(.currentMode, .status, [1]).bytes
        let all = a + b
        #expect(s.append(Array(all[0..<3])).isEmpty)
        let out = s.append(Array(all[3...]))
        #expect(out.map(\.address) == [.battery, .currentMode])
        #expect(out[0].payload == [0x32, 0xff, 0xff, 0x00])
    }
}

// MARK: - Decoders (real captures, QC Ultra gen 1 fw 1.6.7)

@Suite struct DecodeTests {
    @Test func battery() {
        #expect(Decode.battery(hex("32ffff00")) == 50)
        #expect(Decode.battery([0xff]) == nil)
    }

    @Test func eq() {
        let bands = Decode.eq(hex("f60a0800f60a0001f60a0002"))
        #expect(bands == [
            EQBand(kind: .bass, range: -10...10, value: 8),
            EQBand(kind: .mid, range: -10...10, value: 0),
            EQBand(kind: .treble, range: -10...10, value: 0),
        ])
        #expect(Request.setEQ(.bass, value: -3).payload == [0xfd, 0])
        #expect(Request.setEQ(.mid, value: 42).payload == [10, 1])
    }

    @Test func modeSlots() {
        let aware = Decode.modeSlot(hex("0100020000014177617265000000000000000000000000000000000000000000000000000000000000020a01000000"))
        #expect(aware == ModeSlot(index: 1, name: "Aware"))
        let empty = Decode.modeSlot(hex("0300000100004e6f6e65000000000000000000000000000000000000000000000000000000000000000d0a00000100"))
        #expect(empty?.isEmpty == true)
    }

    @Test func misc() {
        #expect(Decode.productName(hex("0041746f6d")) == "Atom")
        #expect(Decode.string(hex("312e362e372b6736656261626432")) == "1.6.7+g6ebabd2")
        #expect(Decode.string(hex("426f736520514320556c747261204865616470686f6e6573")) == "Bose QC Ultra Headphones")
        #expect(Decode.currentMode([0xff]) == nil)
        #expect(Decode.currentMode([2]) == 2)
        #expect(Decode.multipoint([0x07]) == true)
        #expect(Decode.multipoint([0x06]) == false)
    }

    @Test func devices() throws {
        let list = try #require(Decode.pairedDevices(hex("03bc89c1595bfb40fafe3bd78f603e5f0a5dde5023a251bdd4")))
        #expect(list.addresses.map(\.description) == ["bc-89-c1-59-5b-fb", "40-fa-fe-3b-d7-8f",
                                                     "60-3e-5f-0a-5d-de", "50-23-a2-51-bd-d4"])
        #expect(list.connected == Set(list.addresses.prefix(2)))
        #expect(Decode.pairedDevices([0x00, 1, 2]) == nil)

        let mac = try #require(Decode.deviceInfo(hex("bc89c1595bfb0302034d41432d484e4850574b59575956")))
        #expect(mac.name == "MAC-HNHPWKYWYV")
        #expect(mac.isConnected && mac.isActive)
        let phone = try #require(Decode.deviceInfo(hex("40fafe3bd78f01020345676e6f2065646765")))
        #expect(phone.name == "Egno edge")
        #expect(phone.isConnected && !phone.isActive)
        let air = try #require(Decode.deviceInfo(hex("603e5f0a5dde000203416c6578e2809973204d6163426f6f6b20416972")))
        #expect(air.name == "Alex\u{2019}s MacBook Air")
        #expect(!air.isConnected)

        let mba = try #require(DeviceAddress(hex("603e5f0a5dde")))
        #expect(Request.connect(mba).bytes == [4, 1, 5, 7, 0] + mba.bytes)
        #expect(Request.disconnect(mba).bytes == [4, 2, 5, 6] + mba.bytes)
    }
}

// MARK: - Decoders (real captures, QC35 II fw 4.8.1)

@Suite struct QC35DecodeTests {
    @Test func productID() {
        #expect(Decode.productID(hex("402001")) == 0x4020)
        #expect(Decode.productID([0x40]) == nil)
    }

    @Test func anc() {
        #expect(Decode.anc(hex("010b")) == ANCState(level: .high, supported: [.off, .low, .high]))
        #expect(Decode.anc([1]) == nil)
        #expect(Request.setANC(.low).bytes == [1, 6, 2, 1, 3])
    }

    @Test func sidetone() {
        #expect(Decode.sidetone(hex("01000f")) == SidetoneState(level: .off, supported: [.off, .high, .medium, .low]))
        #expect(Request.setSidetone(.medium).bytes == [1, 11, 2, 2, 1, 2])
    }

    @Test func actionButton() {
        // QC35 II: Action button, single press.
        let qc35 = ActionButtonState(buttonID: 0x10, event: 4, action: .noiseCancelling,
                                     supported: [.notConfigured, .voiceAssistant, .noiseCancelling])
        #expect(Decode.actionButton(hex("10040207")) == qc35)
        #expect(qc35.buttonName == "Action button" && qc35.eventName == "single press")
        #expect(Decode.actionButton(hex("100402")) == nil)
        #expect(Request.setActionButton(.voiceAssistant, button: 0x10, event: 4).bytes == [1, 9, 2, 3, 0x10, 4, 1])
    }

    @Test func shortcutButton() throws {
        // QC Ultra gen 1: Shortcut button, long press, 4-byte big-endian mask.
        let ultra = try #require(Decode.actionButton(hex("800913000940" + "0a")))
        #expect(ultra == ActionButtonState(buttonID: 0x80, event: 9, action: .spatialAudio,
                                           supported: [.voiceAssistant, .batteryLevel, .disabled, .spotifyTap, .spatialAudio]))
        #expect(ultra.buttonName == "Shortcut button" && ultra.eventName == "long press")
        #expect(Request.setActionButton(.disabled, button: ultra.buttonID, event: ultra.event).bytes
                == hex("01090203" + "80090e"))

        // QC Ultra gen 2.
        #expect(Decode.actionButton(hex("80090e00094002"))
                == ActionButtonState(buttonID: 0x80, event: 9, action: .disabled,
                                     supported: [.voiceAssistant, .disabled, .spotifyTap, .spatialAudio]))

        // NC 700: press and hold, with an unavailable mask.
        #expect(Decode.actionButton(hex("8005030001208800000080"))
                == ActionButtonState(buttonID: 0x80, event: 5, action: .batteryLevel,
                                     supported: [.batteryLevel, .toggleWakeWord, .windMode, .spotifyTap],
                                     unavailable: [.toggleWakeWord]))
    }

    @Test func unknownButtonActionsDecode() throws {
        // Action 30 and mask bit 30 are unknown; they decode and get a generic label.
        let state = try #require(Decode.actionButton(hex("80091e40000002")))
        #expect(state.action.rawValue == 30)
        #expect(state.action.label == "Action 30")
        #expect(state.supported.map(\.rawValue) == [1, 30])
        #expect(ButtonAction.alexa.label == "Alexa")
    }

    @Test func autoOff() {
        #expect(Decode.autoOff([0x14]) == 20)
        #expect(Request.setAutoOff(minutes: 60).bytes == [1, 4, 2, 1, 60])
    }

    @Test func voicePrompts() throws {
        let vp = try #require(Decode.voicePrompts(hex("a10004cfde")))
        #expect(vp.isOn)
        #expect(vp.language == 1)
        #expect(vp.languageName == "US English")
        #expect(Decode.voicePrompts([0x81])?.isOn == false)
        #expect(Request.setVoicePrompts(on: true, language: 1).payload == [0x21])
    }
}

// MARK: - QC Ultra settings (captures: QC Ultra gen 1 fw 1.6.7, own and bose-rfcomm's)

@Suite struct UltraSettingsTests {
    private let aware = hex("0100020000014177617265000000000000000000000000000000000000000000000000000000000000020a01000000")
    private let empty = hex("0300000100004e6f6e65000000000000000000000000000000000000000000000000000000000000000d0a00000100")

    @Test func selfVoice() {
        // Read `01 03 0f`: low, all four levels supported. Write `[01, level]`.
        #expect(Decode.sidetone(hex("01030f")) == SidetoneState(level: .low, supported: [.off, .high, .medium, .low]))
        #expect(Request.setSidetone(.low).bytes == hex("010b0202" + "0103"))
        #expect(Request.setSidetone(.off).payload == [1, 0])
        #expect(Decode.sidetone([1, 3]) == nil)
    }

    @Test func autoOff() {
        #expect(Decode.autoOff([0x3c]) == 60)
        #expect(Decode.autoOff([0]) == 0)
        #expect(Decode.autoOff([]) == nil)
        #expect(Request.setAutoOff(minutes: 0).bytes == hex("01040201" + "00"))
        #expect(AutoOff.choices.allSatisfy { $0 == 0 || $0 >= 5 })
    }

    @Test func immersiveAudio() {
        #expect(Decode.immersiveAudio([0]) == .off)
        #expect(Decode.immersiveAudio([1]) == .still)
        #expect(Decode.immersiveAudio([2]) == .motion)
        #expect(Decode.immersiveAudio([3]) == nil)
        #expect(Decode.immersiveAudio([]) == nil)
        #expect(Request.setImmersiveAudio(.motion).bytes == hex("050f0201" + "02"))
    }

    @Test func modeConfigRead() throws {
        let config = try #require(Decode.modeConfig(aware))
        #expect(config.index == 1 && config.name == "Aware")
        #expect(config.prompt == 2 && config.promptName == "Aware")
        #expect(!config.userConfigurable && !config.userConfigured && config.isFavorite)
        #expect(config.mutability == [.autoCNC])
        #expect(config.cncLevel == 10 && config.autoCNC)
        #expect(config.spatial == .off && config.windBlock == false)
        #expect(!config.isEmpty)
        #expect(config.slot == Decode.modeSlot(aware))

        let none = try #require(Decode.modeConfig(empty))
        #expect(none.isEmpty && none.name == "None" && none.promptName == "None")
        #expect(none.userConfigurable && !none.userConfigured && !none.isFavorite)
        #expect(none.mutability == [.cncLevel, .spatial, .windBlock])

        // Immersion: motion at byte 44. A wind block mode: byte 46.
        var immersion = aware
        immersion[44] = 2
        immersion[46] = 1
        #expect(Decode.modeConfig(immersion)?.spatial == .motion)
        #expect(Decode.modeConfig(immersion)?.windBlock == true)
        immersion[44] = 9
        #expect(Decode.modeConfig(immersion)?.spatial == nil)

        // A silent user mode has prompt 0 and a real name: stored, not empty.
        var silent = empty
        silent.replaceSubrange(6..<10, with: Array("Desk".utf8))
        #expect(Decode.modeConfig(silent)?.isEmpty == false)
        #expect(ModeConfig.promptName(0x22) == "Immersion" && ModeConfig.promptName(0x0d) == "Focus")
        #expect(ModeConfig.promptName(500) == nil)
    }

    @Test func modeConfigTruncated() {
        // Earbuds stop at 44 bytes, before the spatial and wind bytes.
        let earbuds = try? #require(Decode.modeConfig(Array(aware.prefix(44))))
        #expect(earbuds?.name == "Aware" && earbuds?.cncLevel == 10)
        #expect(earbuds?.spatial == nil && earbuds?.windBlock == nil)
        #expect(Decode.modeConfig(Array(aware.prefix(46)))?.windBlock == nil)
        for length in [0, 1, 6, 38, 43] {
            #expect(Decode.modeConfig(Array(aware.prefix(length))) == nil)
        }
        #expect(Decode.modeConfig([DeviceErrorCode.runtime.rawValue]) == nil)
        #expect(Decode.modeSlot(Array(aware.prefix(37))) == nil)
    }

    @Test func modeConfigWrite() throws {
        // bose-rfcomm's write: `1f 06 02 27  09 0000 "WindTest"…32  00 00 00 01`.
        let wind = ModeEdit(index: 9, name: "WindTest", cncLevel: 4, windBlock: true)
        let name = Array("WindTest".utf8) + [UInt8](repeating: 0, count: 24)
        #expect(Request.setModeConfig(wind).bytes == hex("1f060227") + [9, 0, 0] + name + [0, 0, 0, 1])

        let focus = ModeEdit(index: 3, name: "Focus", prompt: 0x0d, cncLevel: 99, autoCNC: true, spatial: .still)
        let payload = focus.payload
        #expect(payload.count == 39)
        #expect(Array(payload[0..<3]) == [3, 0, 0x0d])
        #expect(Array(payload[35...]) == [10, 1, 1, 0])

        // Editing a record copies its settings, never its 47 bytes.
        var edit = ModeEdit(editing: try #require(Decode.modeConfig(aware)))
        #expect(edit == ModeEdit(index: 1, name: "Aware", prompt: 2, cncLevel: 10, autoCNC: true))
        edit.name = "Walk"
        #expect(edit.payload.count == 39 && edit.payload != Array(aware.prefix(39)))
        #expect(Array(edit.payload[3..<8]) == Array("Walk".utf8) + [0])
    }

    @Test func modeNameTruncatesOnACharacter() {
        func name(_ s: String) -> [UInt8] { Array(ModeEdit(index: 4, name: s).payload[3..<35]) }
        // 31 bytes fit, with the closing NUL.
        let fits = String(repeating: "a", count: 31)
        #expect(name(fits) == Array(fits.utf8) + [0])
        #expect(name(fits + "bc") == Array(fits.utf8) + [0])
        // "é" is 2 bytes: 15 fit (30 bytes); the 16th would end at 32.
        let accents = name(String(repeating: "é", count: 20))
        #expect(Decode.string(accents) == String(repeating: "é", count: 15))
        #expect(accents[30...] == [0, 0])
        // A flag is one character of 8 bytes; it's kept whole or dropped.
        let flags = name(String(repeating: "a", count: 28) + "🇫🇷")
        #expect(Decode.string(flags) == String(repeating: "a", count: 28))
        #expect(name("a\0b") == Array("ab".utf8) + [UInt8](repeating: 0, count: 30))
        #expect(name("") == [UInt8](repeating: 0, count: 32))
    }

    @Test func rememberMode() {
        #expect(Decode.bool([1]) == true)
        #expect(Decode.bool([]) == nil)
        #expect(Request.get(.rememberMode).bytes == hex("1f050100"))
        #expect(Request.setRememberMode(false).bytes == hex("1f050201" + "00"))
        #expect(Request.setRememberMode(true).payload == [1])
    }

    @Test func voicePrompts() throws {
        // English, prompts on, battery announcement on.
        let vp = try #require(Decode.voicePrompts(hex("e10001815e0101")))
        #expect(vp.isOn && vp.language == 1 && vp.languageName == "US English")
        #expect(vp.raw == 0xe1 && vp.batteryAnnouncement == true)
        let spanish = try #require(Decode.voicePrompts(hex("a60001815e0100")))
        #expect(spanish.languageName == "MX Spanish" && spanish.batteryAnnouncement == false)

        // Bits 6-7 go back as read; the announcement is the write's second byte.
        let off = vp.with(isOn: false)
        #expect(!off.isOn && off.raw == 0xc1 && off.language == 1)
        #expect(Request.setVoicePrompts(off, format: .flagsAndBatteryAnnouncement)?.bytes == hex("01030202" + "c101"))
        #expect(Request.setVoicePrompts(vp.with(language: 6, batteryAnnouncement: false),
                                        format: .flagsAndBatteryAnnouncement)?.payload == [0xe6, 0])
        #expect(Request.setVoicePrompts(spanish.with(isOn: true), format: .flagsAndBatteryAnnouncement)?.payload
                == [0xa6, 0])
        #expect(vp.with() == vp)

        // The QC35 II's 5 bytes don't say where the announcement is, so no 2-byte write.
        let qc35 = try #require(Decode.voicePrompts(hex("a10004cfde")))
        #expect(qc35.batteryAnnouncement == nil)
        #expect(Request.setVoicePrompts(qc35, format: .flagsAndBatteryAnnouncement) == nil)
        #expect(Request.setVoicePrompts(qc35.with(isOn: false), format: .flagsOnly)?.payload == [0x01])
        #expect(Request.setVoicePrompts(qc35, format: .flagsOnly) == Request.setVoicePrompts(on: true, language: 1))
        #expect(Decode.voicePrompts([]) == nil)
        #expect(Decode.voicePrompts(hex("e10001815e01"))?.batteryAnnouncement == nil)
    }

    @Test func rename() throws {
        #expect(Decode.productName(hex("00756c7472612d6870")) == "ultra-hp")
        #expect(Decode.productName([]) == "")
        #expect(Request.setProductName("ultra-hp")?.bytes == hex("01020208") + Array("ultra-hp".utf8))
        #expect(Request.setProductName("  Atom \n")?.payload == Array("Atom".utf8))
        #expect(Request.setProductName("   ") == nil)
        let long = try #require(Request.setProductName(String(repeating: "x", count: 40)))
        #expect(long.payload.count == ProductName.maxBytes)
        let accents = try #require(Request.setProductName(String(repeating: "é", count: 20)))
        #expect(accents.payload.count == 30)
        #expect(String(decoding: accents.payload, as: UTF8.self) == String(repeating: "é", count: 15))
    }

    @Test func favorites() throws {
        let read = try #require(Decode.favorites(hex("0a001f")))
        #expect(read.modeCount == 10 && read.modes == [0, 1, 2, 3, 4])
        #expect(read.payload == hex("0a001f"))
        #expect(Decode.favorites(hex("0807"))?.modes == [0, 1, 2])   // QC Earbuds II

        let changed = read.setting(9, favorite: true).setting(3, favorite: false)
        #expect(changed.modes == [0, 1, 2, 4, 9])
        #expect(Request.setFavorites(changed).bytes == hex("1f080203" + "0a0217"))
        #expect(Decode.favorites(changed.payload) == changed)
        // Modes past the mask are dropped rather than written out of bounds.
        #expect(read.setting(10, favorite: true) == read)
        #expect(Favorites(modeCount: 11, modes: [0, 9, 200]).payload == [11, 0x02, 0x01])
        #expect(Favorites(modeCount: 0, modes: [1]).payload == [0])

        #expect(Decode.favorites([]) == nil)
        #expect(Decode.favorites(hex("0a1f")) == nil)   // 10 modes need two mask bytes
        #expect(Decode.favorites([0]) == Favorites(modeCount: 0, modes: []))
        #expect(Decode.favorites([DeviceErrorCode.invalidData.rawValue]) == nil)
    }

    @Test func resetMode() {
        #expect(Request.resetMode(9).bytes == hex("1f090501" + "09"))
    }

    @Test func actions() throws {
        #expect(Request.powerOff().bytes == hex("07040501" + "00"))
        #expect(Request.setPairingMode(true).bytes == hex("04080501" + "01"))
        #expect(Request.setPairingMode(false).payload == [0])
        let mac = try #require(DeviceAddress(hex("bc89c1595bfb")))
        #expect(Request.routeAudio(to: mac).bytes == hex("040c0507" + "82" + "bc89c1595bfb"))
    }
}

@Suite struct ReadoutTests {
    @Test func nowPlaying() {
        // bose-rfcomm: 00 "Not Provided"  03 "1"  04 "1"  06 "0".
        let records = [[0] + Array("Not Provided".utf8), [3] + Array("1".utf8), [4] + Array("1".utf8),
                       [6] + Array("0".utf8)].map { Packet(.nowPlaying, .status, $0) }
        let idle = Decode.nowPlaying(records)
        #expect(idle.title == nil && idle.trackNumber == 1 && idle.totalTracks == 1 && idle.genre == "0")
        #expect(idle.attributes[0] == "Not Provided" && !idle.isEmpty)

        let playing = Decode.nowPlaying([
            Packet(.nowPlaying, .status, [0] + Array("Blue in Green".utf8)),
            Packet(.nowPlaying, .status, [1] + Array("Miles Davis".utf8)),
            Packet(.nowPlaying, .status, []),                 // malformed: skipped
            Packet(.battery, .status, [0, 0x41]),             // another address: skipped
            Packet(.nowPlaying, .status, [3]),                // id with no text
        ])
        #expect(playing.title == "Blue in Green" && playing.text(1) == "Miles Davis")
        #expect(playing.trackNumber == nil && playing.attributes.count == 3)

        #expect(Decode.nowPlaying([]).isEmpty)
        #expect(Decode.nowPlaying([Packet(.nowPlaying, .status, [0] + Array("Not Provided".utf8))]).isEmpty)
        #expect(Decode.nowPlayingRecord([]) == nil)
        #expect(Decode.nowPlayingRecord([4, 0x37])?.text == "7")
        #expect(Request.nowPlaying().bytes == hex("05060500"))
    }

    @Test func serialNumber() {
        #expect(Request.get(.serialNumber).bytes == hex("00070100"))
        #expect(Decode.string(Array("081234Z51234567AE".utf8)) == "081234Z51234567AE")
        #expect(Decode.string([]) == "")
    }

    @Test func audioSource() throws {
        let playing = try #require(Decode.audioSource(hex("000f01" + "bc89c1595bfb")))
        #expect(playing.kind == .bluetooth && playing.supported == 0x000f)
        #expect(playing.device?.description == "bc-89-c1-59-5b-fb")
        #expect(Decode.audioSource(hex("000f00")) == AudioSource(kind: AudioSource.Kind.none, device: nil, supported: 0x0f))
        #expect(Decode.audioSource(hex("000f02"))?.kind == .aux)
        #expect(Decode.audioSource(hex("000f07"))?.kind == nil)
        // A Bluetooth source with a short address: the type survives, the device doesn't.
        #expect(Decode.audioSource(hex("000f01bc89")) == AudioSource(kind: .bluetooth, device: nil, supported: 0x0f))
        #expect(Decode.audioSource(hex("000f")) == nil)
        #expect(Decode.audioSource([]) == nil)
    }

    @Test func batteryReadings() {
        // QC Ultra gen 1: minutes unknown.
        #expect(Decode.batteryReadings(hex("32ffff00"))
                == [BatteryReading(percent: 50, minutesRemaining: nil, component: 0)])
        #expect(Decode.batteryReadings(hex("5a04b000"))
                == [BatteryReading(percent: 90, minutesRemaining: 1200, component: 0)])
        // Earbuds: one record per bud.
        #expect(Decode.batteryReadings(hex("64ffff01" + "5a012c02")).map(\.minutesRemaining) == [nil, 300])
        // QC35: a lone percent.
        #expect(Decode.batteryReadings([0x46]) == [BatteryReading(percent: 70, minutesRemaining: nil, component: nil)])
        #expect(Decode.batteryReadings([0xff]).first?.percent == nil)
        #expect(Decode.batteryReadings([]).isEmpty)
        // Short and ragged payloads keep what's whole.
        #expect(Decode.batteryReadings(hex("32ffff")) == [BatteryReading(percent: 50, minutesRemaining: nil, component: nil)])
        #expect(Decode.batteryReadings(hex("32ffff00" + "5a04")).count == 1)
        // The percent-only decoder is unchanged.
        #expect(Decode.battery(hex("5a04b000")) == 90)
    }

    /// Error replies carry one code byte; no decoder may trap on it or on nothing.
    @Test func shortPayloadsNeverTrap() {
        for payload in [[], [0x05], [0xff, 0xff]] as [[UInt8]] {
            _ = Decode.battery(payload); _ = Decode.batteryReadings(payload); _ = Decode.string(payload)
            _ = Decode.productName(payload); _ = Decode.eq(payload); _ = Decode.currentMode(payload)
            _ = Decode.modeSlot(payload); _ = Decode.modeConfig(payload); _ = Decode.bool(payload)
            _ = Decode.pairedDevices(payload); _ = Decode.deviceInfo(payload); _ = Decode.multipoint(payload)
            _ = Decode.productID(payload); _ = Decode.anc(payload); _ = Decode.sidetone(payload)
            _ = Decode.actionButton(payload); _ = Decode.autoOff(payload); _ = Decode.voicePrompts(payload)
            _ = Decode.immersiveAudio(payload); _ = Decode.favorites(payload); _ = Decode.audioSource(payload)
            _ = Decode.nowPlayingRecord(payload)
        }
    }
}

// MARK: - Profiles

@Suite struct ProfileTests {
    @Test func lookup() {
        #expect(ModelRegistry.profile(forProductID: 0x4066).id == "qc-ultra-1")
        #expect(ModelRegistry.profile(forProductID: 0x4020).id == "qc35-2")
        let unknown = ModelRegistry.profile(forProductID: 0x1234, name: "Mystery")
        #expect(unknown.id == "generic")
        #expect(unknown.productIDs == [0x1234])
        #expect(unknown.displayName == "Mystery")
        #expect(ModelRegistry.profile(forProductID: 0x1234).displayName.contains("0x1234"))
        #expect(!unknown.verified)
    }

    @Test func features() {
        let qc35 = ModelProfile.qc35II
        for f in [Feature.eq, .modes, .multipoint, .autoPause, .autoAnswer, .modelName] {
            #expect(!qc35.supports(f), "QC35 II must not request \(f)")
        }
        #expect(qc35.supports(.ancLevel) && qc35.supports(.pairedDevices))
        #expect(ModelProfile.qcUltra.supports(.modes) && !ModelProfile.qcUltra.supports(.ancLevel))
        #expect(ModelProfile.qcUltra.supports(.actionButton) && qc35.supports(.actionButton))
        #expect(ModelProfile.generic().features == [.productName, .firmware, .battery, .pairedDevices])
    }

    @Test func qcUltraSettings() {
        let ultra = ModelProfile.qcUltra, qc35 = ModelProfile.qc35II
        let added: [Feature] = [.serialNumber, .rename, .immersiveAudio, .customModes, .rememberMode, .favorites,
                                .nowPlaying, .audioSource, .powerOff, .pairingMode, .audioRouting]
        for f in added {
            #expect(ultra.supports(f), "QC Ultra should have \(f)")
            #expect(!qc35.supports(f) && !ModelProfile.generic().supports(f), "\(f) is QC Ultra only")
        }
        #expect(ultra.supports(.sidetone) && ultra.supports(.autoOff) && ultra.supports(.voicePrompts))
        #expect(ultra.voicePromptsFormat == .flagsAndBatteryAnnouncement)
        #expect(qc35.voicePromptsFormat == .flagsOnly && ModelProfile.generic().voicePromptsFormat == .flagsOnly)

        let reads = ultra.settingAddresses
        for address in [Address.sidetone, .autoOff, .voicePrompts, .serialNumber, .audioSource,
                        .immersiveAudio, .rememberMode, .favorites] {
            #expect(reads.contains(address), "QC Ultra should read \(address)")
            #expect(ModelProfile.generic().settingAddresses.contains(address) == false)
        }
        // Enumerations, indexed reads and actions aren't plain GETs.
        for address in [Address.nowPlaying, .modeConfig, .resetMode, .power, .pairingMode, .audioRouting] {
            #expect(!reads.contains(address))
        }
        #expect(!qc35.settingAddresses.contains(.serialNumber))
    }

    @Test func noiseControl() throws {
        guard case .modes(let layout) = ModelProfile.qcUltra.noiseControl else {
            Issue.record("QC Ultra should use modes"); return
        }
        #expect(layout.slots == 0...9)
        #expect(layout.presetCount == 3)
        #expect(layout.preset(at: 1).symbol == "ear")
        #expect(layout.preset(at: 5).name == nil)
        #expect(ModelProfile.qc35II.noiseControl == .ancLevels([.off, .low, .high]))
    }

    @Test func reads() {
        let qc35 = ModelProfile.qc35II.settingAddresses
        #expect(qc35.first == .productName)
        #expect(!qc35.contains(.eq) && !qc35.contains(.currentMode) && qc35.contains(.ancLevel))
        #expect(ModelProfile.qc35II.pollAddresses == [.battery, .ancLevel])
        #expect(ModelProfile.qcUltra.pollAddresses == [.battery, .currentMode])
        #expect(ModelProfile.generic().settingAddresses == [.productName, .firmware, .battery])
    }

    @Test func channels() {
        let channels = ModelRegistry.knownChannels
        #expect(channels.contains(2) && channels.contains(8))
        #expect(Set(channels).count == channels.count)
    }
}

// MARK: - Client

@MainActor
final class FakeTransport: BMAPTransport {
    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?
    var written: [[UInt8]] = []
    var responder: (([UInt8]) -> [UInt8]?)?

    func write(_ bytes: [UInt8]) throws {
        written.append(bytes)
        if let reply = responder?(bytes) {
            Task { @MainActor in self.onReceive?(reply) }
        }
    }

    func close() {}
    func deliver(_ p: Packet) { onReceive?(p.bytes) }
}

@MainActor @Suite struct ClientTests {
    @Test func matchesReplyByAddress() async throws {
        let t = FakeTransport()
        t.responder = { _ in
            Packet(.currentMode, .status, [9]).bytes + Packet(.battery, .status, [77]).bytes
        }
        let c = BMAPClient(transport: t)
        var notes: [Packet] = []
        c.onNotification = { notes.append($0) }

        let reply = try await c.send(Request.get(.battery))
        #expect(reply.payload == [77])
        #expect(notes.map(\.address) == [.currentMode])
    }

    @Test func throwsDeviceError() async {
        let t = FakeTransport()
        t.responder = { _ in Packet(.modeConfig, .error, [5]).bytes }
        let c = BMAPClient(transport: t)
        await #expect(throws: BMAPError.device(.modeConfig, .operatorNotSupported)) {
            try await c.send(Request.get(.modeConfig))
        }
    }

    @Test func timesOut() async {
        let c = BMAPClient(transport: FakeTransport())
        await #expect(throws: BMAPError.timeout(.battery)) {
            try await c.send(Request.get(.battery), timeout: .milliseconds(50))
        }
    }

    @Test func serializesRequests() async throws {
        let t = FakeTransport()
        t.responder = { bytes in Packet(Address(bytes[0], bytes[1]), .status, [bytes[1]]).bytes }
        let c = BMAPClient(transport: t)
        async let a = c.send(Request.get(.firmware))
        async let b = c.send(Request.get(.productID))
        let (ra, rb) = try await (a, b)
        #expect(ra.payload == [5])
        #expect(rb.payload == [3])
        #expect(t.written.count == 2)
    }

    @Test func enumerateCollectsRecordsUntilResult() async throws {
        let t = FakeTransport()
        t.responder = { _ in
            Packet(.nowPlaying, .processing).bytes
                + Packet(.nowPlaying, .status, [0] + Array("Song".utf8)).bytes
                + Packet(.currentMode, .status, [2]).bytes
                + Packet(.nowPlaying, .status, [3, 0x34]).bytes
                + Packet(.nowPlaying, .result).bytes
                + Packet(.nowPlaying, .status, [9]).bytes   // after the end: not ours
        }
        let c = BMAPClient(transport: t)
        var notes: [Packet] = []
        c.onNotification = { notes.append($0) }

        let records = try await c.enumerate(Request.nowPlaying())
        #expect(records.map(\.payload) == [[0] + Array("Song".utf8), [3, 0x34]])
        #expect(Decode.nowPlaying(records).title == "Song")
        #expect(notes == [Packet(.currentMode, .status, [2]), Packet(.nowPlaying, .status, [9])])

        // The next request isn't confused by the listing.
        t.responder = { _ in Packet(.battery, .status, [77]).bytes }
        #expect(try await c.send(Request.get(.battery)).payload == [77])
    }

    @Test func enumerateHandlesEmptyErrorAndSilence() async throws {
        let t = FakeTransport()
        let c = BMAPClient(transport: t)
        t.responder = { _ in Packet(.nowPlaying, .processing).bytes + Packet(.nowPlaying, .result).bytes }
        #expect(try await c.enumerate(Request.nowPlaying()).isEmpty)

        t.responder = { _ in Packet(.nowPlaying, .error, [8]).bytes }
        await #expect(throws: BMAPError.device(.nowPlaying, .runtime)) {
            try await c.enumerate(Request.nowPlaying())
        }
        // An error with no code byte, and one this library has no name for.
        t.responder = { _ in Packet(.power, .error).bytes }
        await #expect(throws: BMAPError.device(.power, nil)) { try await c.send(Request.powerOff()) }
        t.responder = { _ in Packet(.audioRouting, .error, [0x18]).bytes }
        await #expect(throws: BMAPError.device(.audioRouting, nil)) {
            try await c.enumerate(Packet(.audioRouting, .start))
        }

        // PROCESSING and a record, then nothing.
        t.responder = { _ in Packet(.nowPlaying, .processing).bytes + Packet(.nowPlaying, .status, [0, 0x41]).bytes }
        await #expect(throws: BMAPError.timeout(.nowPlaying)) {
            try await c.enumerate(Request.nowPlaying(), timeout: .milliseconds(50))
        }
    }

    @Test func failsPendingOnClose() async {
        let t = FakeTransport()
        let c = BMAPClient(transport: t)
        Task { @MainActor in t.onClose?() }
        await #expect(throws: BMAPError.disconnected) {
            try await c.send(Request.get(.battery))
        }
    }
}
