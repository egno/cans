import AppKit
import BMAP
import Foundation
import os

private let log = Logger(subsystem: "io.github.egno.cans", category: "scripting")

// The scripting surface: the same few commands reach the running app as `cans://` URLs or
// from the command line (`CommandLine.swift`). Parsing and formatting are plain values;
// `ScriptRunner` carries the commands out.

struct ScriptError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum ScriptCommand: Equatable {
    enum Switch: String { case on, off, toggle }

    case help
    case status(json: Bool)
    case presets
    case mode(String)
    case eq(String)
    case thisMacOnly(Switch)
    case immersive(ImmersiveAudio)
    case powerOff
    case connect(String)
    case disconnect(String)
}

struct ScriptRequest: Equatable {
    var command: ScriptCommand
    /// Name or Bluetooth address of the pair; nil for the one the popover shows.
    var headset: String?
}

enum ScriptParser {
    static let commands = ["status", "presets", "mode", "eq", "this-mac-only", "connect", "disconnect", "immersive", "power-off",
                           "help"]

    static let usage = """
        Usage: cans <command> [--headset <name or address>]

          status [--json]              Connected headphones: battery, mode, equalizer, devices, what's playing
          mode <name>                  Switch listening mode or noise cancelling level
          eq <preset>                  Apply an equalizer preset
          presets                      List equalizer presets
          this-mac-only [on|off|toggle]
                                       Disconnect the headphones' other devices, or bring them back
          connect <device>             Connect one of the headphones' paired devices
          disconnect <device>          Disconnect one
          immersive off|still|motion   Set immersive (spatial) audio
          power-off                    Turn the headphones off

        Commands go to the running Cans app and act on the headphones shown in its popover
        unless --headset names another pair. Names match without case, and a unique beginning
        is enough. The same commands work as URLs: cans://mode/Quiet?headset=Atom
        """

    /// True when the process was started as the command line tool rather than as the app.
    static func isCommandLine(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return commands.contains(first) || first == "--help" || first == "-h"
    }

    static func parse(_ arguments: [String]) throws(ScriptError) -> ScriptRequest {
        var words: [String] = []
        var headset: String?
        var json = false
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--headset" {
                guard let value = rest.popFirst() else { throw ScriptError("--headset needs a name or address") }
                headset = value
            } else if argument.hasPrefix("--headset=") {
                headset = String(argument.dropFirst("--headset=".count))
            } else if argument == "--json" {
                json = true
            } else if argument == "--help" || argument == "-h" {
                return ScriptRequest(command: .help)
            } else if argument.hasPrefix("--") {
                throw ScriptError("Unknown option \(argument)")
            } else {
                words.append(argument)
            }
        }
        guard let name = words.first else { throw ScriptError("No command given") }
        // "Bass boost" may arrive as two words.
        let operand = words.dropFirst().joined(separator: " ")
        func required(_ what: String) throws(ScriptError) -> String {
            guard !operand.isEmpty else { throw ScriptError("\(name) needs \(what)") }
            return operand
        }
        let command: ScriptCommand
        switch name {
        case "help": command = .help
        case "status": command = .status(json: json)
        case "presets": command = .presets
        case "mode": command = .mode(try required("a mode name"))
        case "eq": command = .eq(try required("a preset name"))
        case "connect": command = .connect(try required("a device name"))
        case "disconnect": command = .disconnect(try required("a device name"))
        case "this-mac-only":
            guard let action = operand.isEmpty ? .toggle : ScriptCommand.Switch(rawValue: operand.lowercased()) else {
                throw ScriptError("this-mac-only takes on, off or toggle")
            }
            command = .thisMacOnly(action)
        case "immersive":
            guard let mode = ImmersiveAudio.allCases.first(where: { $0.label.lowercased() == operand.lowercased() }) else {
                throw ScriptError("immersive takes off, still or motion")
            }
            command = .immersive(mode)
        case "power-off":
            guard operand.isEmpty else { throw ScriptError("power-off takes nothing after it") }
            command = .powerOff
        default: throw ScriptError("Unknown command \(name)")
        }
        return ScriptRequest(command: command, headset: headset.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `cans://mode/Quiet?headset=Atom` as the arguments `mode Quiet --headset Atom`.
    static func arguments(from url: URL) -> [String]? {
        guard url.scheme?.lowercased() == "cans", let command = url.host(percentEncoded: false),
              !command.isEmpty else { return nil }
        var arguments = [command.lowercased()] + url.pathComponents.filter { $0 != "/" }
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            switch item.name {
            case "headset": if let value = item.value, !value.isEmpty { arguments += ["--headset", value] }
            case "json": if item.value != "0" { arguments.append("--json") }
            default: break
            }
        }
        return arguments
    }
}

/// Finds what a typed name means: the exact name without case, otherwise the only one it
/// begins, otherwise the only one that contains it.
enum NameMatch {
    static func find<T>(_ wanted: String, in items: [T], kind: String, name: (T) -> String) throws(ScriptError) -> T {
        let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        let names = items.map { name($0).lowercased() }
        if let exact = names.firstIndex(of: key) { return items[exact] }
        for test in [{ (n: String) in n.hasPrefix(key) }, { (n: String) in n.contains(key) }] {
            let hits = names.indices.filter { test(names[$0]) }
            if hits.count == 1 { return items[hits[0]] }
            if hits.count > 1 {
                throw ScriptError("“\(wanted)” fits several \(kind)s: \(hits.map { name(items[$0]) }.joined(separator: ", "))")
            }
        }
        let known = items.isEmpty ? "there are none" : "there's \(items.map(name).joined(separator: ", "))"
        throw ScriptError("No \(kind) named “\(wanted)”; \(known)")
    }
}

/// One pair as `status` reports it.
struct HeadsetStatus: Encodable, Equatable {
    struct Device: Encodable, Equatable {
        var name: String
        var connected: Bool
        var active: Bool
        var thisMac: Bool
        /// The headphones are playing from this device.
        var playing = false
    }

    struct Track: Encodable, Equatable {
        var title: String?
        var trackNumber: Int?
        var totalTracks: Int?
    }

    struct Equalizer: Encodable, Equatable {
        var bass: Int
        var mid: Int
        var treble: Int
        var preset: String?
    }

    var name: String
    var model: String
    var address: String
    /// The pair the popover shows, which commands act on by default.
    var selected: Bool
    var battery: Int?
    var mode: String?
    var modes: [String]
    /// The Mac's sound plays on this pair.
    var playingMacAudio: Bool
    var equalizer: Equalizer?
    var devices: [Device]
    // What only some models report; left out of the output when they don't.
    var firmware: String?
    var serialNumber: String?
    var batteryMinutesRemaining: Int?
    /// "off", "still" or "motion".
    var immersiveAudio: String?
    /// The modes the headphones' button cycles through.
    var favoriteModes: [String]?
    var rememberMode: Bool?
    var nowPlaying: Track?

    var text: String {
        var lines = ["\(name)\(selected ? " (selected)" : "")", "  model: \(model)"]
        if let battery {
            let left = batteryMinutesRemaining.map { ", about \(playTimeLabel(minutes: $0)) left" } ?? ""
            lines.append("  battery: \(battery)%\(left)")
        }
        if !modes.isEmpty || mode != nil { lines.append("  mode: \(mode ?? "unknown")") }
        if !modes.isEmpty { lines.append("  modes: \(modes.joined(separator: ", "))") }
        if let immersiveAudio { lines.append("  immersive audio: \(immersiveAudio)") }
        lines.append("  mac audio: \(playingMacAudio ? "yes" : "no")")
        if let equalizer {
            let preset = EQPreset(name: "", bass: equalizer.bass, mid: equalizer.mid, treble: equalizer.treble)
            lines.append("  equalizer: \(equalizer.preset.map { "\($0) (\(preset.summary))" } ?? preset.summary)")
        }
        if !devices.isEmpty {
            let described = devices.map { device in
                device.name + (device.playing ? " (playing)" : device.active ? " (active)" : device.connected ? " (connected)" : "")
            }
            lines.append("  devices: \(described.joined(separator: ", "))")
        }
        if let title = nowPlaying?.title { lines.append("  now playing: \(title)") }
        if let firmware { lines.append("  firmware: \(firmware)") }
        if let serialNumber { lines.append("  serial number: \(serialNumber)") }
        return lines.joined(separator: "\n")
    }

    static func text(_ all: [HeadsetStatus]) -> String {
        all.isEmpty ? "No headphones connected" : all.map(\.text).joined(separator: "\n\n")
    }

    static func json(_ all: [HeadsetStatus]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(all)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

struct ScriptResult: Equatable {
    var ok: Bool
    var output: String
}

/// Carries out scripting commands against the manager, waiting for the headphones' answer
/// so the caller gets a result rather than a hope.
@MainActor
final class ScriptRunner {
    private let manager: HeadphonesManager
    /// Recent failures the manager reported, newest last, with the pair they're about.
    private var failures: [(number: Int, address: String, message: String)] = []
    /// How many there have been; a command only looks at ones after it began.
    private var failureCount = 0

    init(manager: HeadphonesManager) {
        self.manager = manager
        manager.onFailure = { [weak self] session, message in
            guard let self else { return }
            self.failureCount += 1
            self.failures = self.failures.suffix(20) + [(self.failureCount, session.address, message)]
        }
    }

    /// A `cans://` URL. There's nobody to answer, so problems go to the popover's banner.
    func open(_ url: URL) {
        guard let arguments = ScriptParser.arguments(from: url) else {
            manager.showProblem("Cans doesn't understand \(url.absoluteString)")
            return
        }
        Task {
            let result = await run(arguments)
            if !result.ok { manager.showProblem(result.output) }
        }
    }

    func run(_ arguments: [String]) async -> ScriptResult {
        do {
            let request = try ScriptParser.parse(arguments)
            let output = try await perform(request)
            return ScriptResult(ok: true, output: output)
        } catch {
            log.info("\(arguments.first ?? "", privacy: .public) failed: \(error.message, privacy: .public)")
            return ScriptResult(ok: false, output: error.message)
        }
    }

    private func perform(_ request: ScriptRequest) async throws(ScriptError) -> String {
        switch request.command {
        case .help:
            return ScriptParser.usage
        case .presets:
            return manager.eqPresets.all.map { "\($0.name): \($0.summary)" }.joined(separator: "\n")
        case .status(let json):
            await waitForHeadphones()
            var sessions = manager.sessions
            if let headset = request.headset { sessions = [try await session(named: headset)] }
            let all = sessions.map(status)
            return json ? HeadsetStatus.json(all) : HeadsetStatus.text(all)
        case .mode(let name):
            let session = try await session(named: request.headset)
            let options = session.noiseOptions
            guard !options.isEmpty else { throw ScriptError("\(session.displayName) has no modes to switch") }
            let option = try NameMatch.find(name, in: options, kind: "mode", name: \.name)
            if session.currentNoiseSetting != option.setting {
                try await writing(to: session, 1) { session.apply(option.setting) }
            }
            return session.noiseControlSummary ?? option.name
        case .eq(let name):
            let session = try await session(named: request.headset)
            guard session.profile.supports(.eq), !session.eq.isEmpty else {
                throw ScriptError("\(session.displayName) has no equalizer")
            }
            let preset = try NameMatch.find(name, in: manager.eqPresets.all, kind: "preset", name: \.name)
            let changes = session.eq.filter { $0.value != preset.value(for: $0) }.count
            try await writing(to: session, changes) { session.apply(preset) }
            return "Equalizer: \(preset.name) (\(preset.summary))"
        case .thisMacOnly(let action):
            return try await thisMacOnly(action, on: try await session(named: request.headset))
        case .immersive(let mode):
            let session = try await session(named: request.headset)
            guard session.profile.supports(.immersiveAudio), session.immersiveAudio != nil else {
                throw ScriptError("\(session.displayName) has no immersive audio setting")
            }
            if session.immersiveAudio != mode {
                try await writing(to: session, 1) { session.setImmersiveAudio(mode) }
            }
            // What the headphones answered, which is theirs to decide.
            return "Immersive audio: \((session.immersiveAudio ?? mode).label.lowercased())"
        case .powerOff:
            let session = try await session(named: request.headset)
            guard session.profile.supports(.powerOff) else {
                throw ScriptError("\(session.displayName) can't be turned off from here")
            }
            let mark = failureCount, before = session.completedWrites
            session.powerOff()
            // The link dropping is the answer; the session gives up waiting for it on its own.
            await wait(upTo: .seconds(15)) { session.isClosed || session.completedWrites > before }
            try check(session, since: mark)
            guard session.isClosed else { throw ScriptError("\(session.displayName) stayed on") }
            return "Turned off \(session.displayName)"
        case .connect(let name):
            let session = try await session(named: request.headset)
            let device = try self.device(named: name, on: session)
            let title = session.displayName(of: device)
            guard !device.isConnected else { return "\(title) is already connected" }
            try await changingDevices(on: session) { session.connect(device) }
            return "Connected \(title)"
        case .disconnect(let name):
            let session = try await session(named: request.headset)
            let device = try self.device(named: name, on: session)
            guard !session.isThisMac(device) else {
                throw ScriptError("Cans runs on this Mac and would lose the headphones with it")
            }
            guard device.isConnected else { return "\(device.name) isn't connected" }
            try await changingDevices(on: session) { session.disconnect(device) }
            return "Disconnected \(device.name)"
        }
    }

    private func thisMacOnly(_ action: ScriptCommand.Switch, on session: HeadphoneSession) async throws(ScriptError) -> String {
        guard session.profile.supports(.pairedDevices) else {
            throw ScriptError("\(session.displayName) doesn't list its devices")
        }
        let store = manager.thisMacOnly
        store.forgetReconnected(session)
        let others = store.others(of: session)
        if action == .on || (action == .toggle && !others.isEmpty) {
            guard !others.isEmpty else { return "Only this Mac is connected" }
            try await changingDevices(on: session) { store.engage(session) }
            return "Disconnected \(listed(others.map(\.name)))"
        }
        let back = store.reconnectable(for: session)
        guard !back.isEmpty else { return "Nothing to reconnect" }
        try await changingDevices(on: session) { store.reconnect(session) }
        return "Connected \(listed(back.map(\.name)))"
    }

    // MARK: - Finding things

    /// The named pair, or the one the popover shows; once its settings have been read.
    private func session(named name: String?) async throws(ScriptError) -> HeadphoneSession {
        await waitForHeadphones()
        guard !manager.sessions.isEmpty else { throw ScriptError("No headphones connected") }
        let session: HeadphoneSession
        if let name {
            let address = AudioOutput.normalized(name)
            if address.count == 12, let exact = manager.sessions.first(where: { AudioOutput.normalized($0.address) == address }) {
                session = exact
            } else {
                session = try NameMatch.find(name, in: manager.sessions, kind: "pair", name: \.displayName)
            }
        } else if let selected = manager.selected {
            session = selected
        } else {
            throw ScriptError("No headphones connected")
        }
        await wait(upTo: .seconds(10)) { session.isLoaded || session.isClosed }
        guard session.isLoaded, !session.isClosed else {
            throw ScriptError("\(session.displayName) didn't finish connecting")
        }
        return session
    }

    /// A URL may have just launched Cans: give a search under way the chance to find a pair.
    private func waitForHeadphones() async {
        await wait(upTo: .seconds(10)) { self.manager.status != .searching }
    }

    private func device(named name: String, on session: HeadphoneSession) throws(ScriptError) -> DeviceInfo {
        guard session.profile.supports(.pairedDevices) else {
            throw ScriptError("\(session.displayName) doesn't list its devices")
        }
        let address = AudioOutput.normalized(name)
        if address.count == 12, let exact = session.devices.first(where: { AudioOutput.normalized($0.address.description) == address }) {
            return exact
        }
        // "this Mac" for the Mac, whatever it's called.
        return try NameMatch.find(name, in: session.devices, kind: "device", name: session.displayName(of:))
    }

    private func status(_ session: HeadphoneSession) -> HeadsetStatus {
        let options = session.noiseOptions
        let equalizer: HeadsetStatus.Equalizer? = session.eq.isEmpty ? nil : {
            let values = EQPreset(name: "", bands: session.eq)
            return .init(bass: values.bass, mid: values.mid, treble: values.treble,
                         preset: manager.eqPresets.match(session.eq)?.name)
        }()
        return HeadsetStatus(
            name: session.displayName, model: session.modelName, address: session.address,
            selected: session === manager.selected, battery: session.battery,
            mode: options.first { $0.setting == session.currentNoiseSetting }?.name,
            modes: options.map(\.name), playingMacAudio: manager.isPlayingHere(session), equalizer: equalizer,
            devices: session.devices.map {
                .init(name: session.displayName(of: $0), connected: $0.isConnected, active: $0.isActive,
                      thisMac: session.isThisMac($0), playing: session.playingDevice?.address == $0.address)
            },
            firmware: session.firmware, serialNumber: session.serial.flatMap { $0.isEmpty ? nil : $0 },
            batteryMinutesRemaining: session.batteryMinutes,
            immersiveAudio: session.immersiveAudio?.label.lowercased(),
            favoriteModes: session.favorites.map { set in session.modes.filter { set.contains($0.index) }.map(\.name) },
            rememberMode: session.rememberMode,
            nowPlaying: session.nowPlaying.map {
                .init(title: $0.title, trackNumber: $0.trackNumber, totalTracks: $0.totalTracks)
            })
    }

    // MARK: - Waiting for the headphones

    /// Runs `action`, which sends `count` writes, and waits until the headphones have
    /// answered them all. Throws what the session reported if one failed.
    private func writing(to session: HeadphoneSession, _ count: Int, _ action: () -> Void) async throws(ScriptError) {
        let mark = failureCount, before = session.completedWrites
        action()
        await wait(upTo: .seconds(10)) { session.completedWrites >= before + count || session.isClosed }
        try check(session, since: mark)
        guard session.completedWrites >= before + count else {
            throw ScriptError(session.isClosed ? "\(session.displayName) disconnected" : "The headphones didn't respond")
        }
    }

    /// Runs `action`, which starts connects or disconnects, and waits for their results;
    /// the session gives up on one after 20 s and reports it.
    private func changingDevices(on session: HeadphoneSession, _ action: () -> Void) async throws(ScriptError) {
        let mark = failureCount
        action()
        await wait(upTo: .seconds(30)) { session.pendingDevices.isEmpty || session.isClosed }
        // Connecting a device can push this Mac out; the session closing isn't a failure then.
        try check(session, since: mark)
    }

    private func check(_ session: HeadphoneSession, since mark: Int) throws(ScriptError) {
        if let failure = failures.first(where: { $0.number > mark && $0.address == session.address }) {
            throw ScriptError(failure.message)
        }
    }

    private func wait(upTo limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
