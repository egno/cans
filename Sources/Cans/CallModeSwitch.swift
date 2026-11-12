import BMAP
import CoreAudio
import Foundation
import Observation
import os

private let log = Logger(subsystem: "io.github.egno.cans", category: "calls")

// MARK: - Detection

/// Turns "the Mac's microphone is in use" into calls starting and ending.
///
/// The microphone opens for moments that aren't calls (dictation checking the level, an app
/// probing its devices) and closes for a moment inside one (the input switching to the
/// headset), so a change only counts once it has lasted. No Core Audio here: the caller
/// feeds it the state and the time.
struct CallDetector {
    enum Event: Equatable { case started, ended }

    /// How long the microphone must stay in use before it's a call.
    var startDelay: Duration = .milliseconds(1500)
    /// How long it must stay idle before the call is over.
    var endDelay: Duration = .seconds(3)

    private(set) var isInCall = false
    /// Since when the microphone has disagreed with `isInCall`.
    private var changedAt: ContinuousClock.Instant?

    /// Reports the microphone's state. Returns when to call `settle`, or nil when there's
    /// nothing to wait for.
    mutating func microphone(inUse: Bool, at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard inUse != isInCall else {
            changedAt = nil
            return nil
        }
        let since = changedAt ?? now
        changedAt = since
        return since + delay
    }

    /// The event, once the last change has lasted long enough.
    mutating func settle(at now: ContinuousClock.Instant) -> Event? {
        guard let changedAt, now >= changedAt + delay else { return nil }
        self.changedAt = nil
        isInCall.toggle()
        return isInCall ? .started : .ended
    }

    private var delay: Duration { isInCall ? endDelay : startDelay }
}

/// What to set on one pair when a call starts and what to put back when it ends.
///
/// Nothing is put back when the pair was already on the call setting, when what it was on
/// isn't known, or when the setting changed during the call: that was the user, on the
/// headphones or in an app, and their choice stands.
struct CallModePlan<Setting: Equatable> {
    private struct Engaged {
        let call: Setting
        let previous: Setting
    }

    private var engaged: Engaged?

    /// True while there's a setting to put back.
    var willRestore: Bool { engaged != nil }

    /// The setting to switch to, or nil when the pair is already on it.
    mutating func callStarted(current: Setting?, callSetting: Setting) -> Setting? {
        engaged = nil
        guard current != callSetting else { return nil }
        if let current { engaged = Engaged(call: callSetting, previous: current) }
        return callSetting
    }

    /// The pair's setting changed, by anyone. Our own switch arrives here too and is ignored.
    mutating func settingChanged(to current: Setting?) {
        if let engaged, current != engaged.call { self.engaged = nil }
    }

    /// The setting to go back to, if any.
    mutating func callEnded(current: Setting?) -> Setting? {
        defer { engaged = nil }
        guard let engaged, current == engaged.call else { return nil }
        return engaged.previous
    }
}

// MARK: - Noise settings

/// A listening mode or a noise cancelling level: whichever the model has.
enum NoiseSetting: Hashable {
    case mode(UInt8)
    case anc(ANCLevel)

    /// "mode:3" or "anc:1", for preferences.
    var stored: String {
        switch self {
        case .mode(let index): "mode:\(index)"
        case .anc(let level): "anc:\(level.rawValue)"
        }
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let value = UInt8(parts[1]) else { return nil }
        switch parts[0] {
        case "mode": self = .mode(value)
        case "anc":
            guard let level = ANCLevel(rawValue: value) else { return nil }
            self = .anc(level)
        default: return nil
        }
    }
}

extension HeadphoneSession {
    struct NoiseOption: Identifiable, Equatable {
        let setting: NoiseSetting
        /// "Quiet", or "High" for a noise cancelling level.
        let name: String
        var id: NoiseSetting { setting }
    }

    /// The modes or noise cancelling levels this pair can be switched to, in the popover's order.
    var noiseOptions: [NoiseOption] {
        if modeLayout != nil {
            return modes.map { NoiseOption(setting: .mode($0.index), name: $0.name) }
        }
        if case .ancLevels(let defaults) = profile.noiseControl, profile.supports(.ancLevel), let anc {
            let levels = anc.supported.isEmpty ? defaults : anc.supported
            return levels.map { NoiseOption(setting: .anc($0), name: $0.label) }
        }
        return []
    }

    var currentNoiseSetting: NoiseSetting? {
        if modeLayout != nil { return currentMode.map(NoiseSetting.mode) }
        return anc?.level.map(NoiseSetting.anc)
    }

    func apply(_ setting: NoiseSetting) {
        switch setting {
        case .mode(let index): selectMode(index)
        case .anc(let level): setANC(level)
        }
    }
}

// MARK: - Microphone

/// Whether any process is using the Mac's default input device, kept current through Core
/// Audio listeners. Reading this needs no microphone permission: Cans never opens the input.
@MainActor
final class MicrophoneMonitor {
    /// Called after every read; the state may be unchanged.
    var onChange: (() -> Void)?
    private(set) var isInUse = false
    /// The default input's UID; a pair's hands-free microphone starts with its Bluetooth address.
    private(set) var inputUID: String?

    private var device: AudioObjectID?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var isStarted = false

    /// Listens for the app's lifetime; the listeners are never removed.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
        inputChanged()
    }

    /// Moves the in-use listener to the new default input: a call often changes it to the headset.
    private func inputChanged() {
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(kAudioObjectUnknown)
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        let current = status == noErr && id != kAudioObjectUnknown ? id : nil
        if current != device {
            var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if let device, let runningListener {
                // Fails when the device is already gone, which removes the listener too.
                AudioObjectRemovePropertyListenerBlock(device, &running, .main, runningListener)
            }
            device = current
            runningListener = nil
            if let current {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.read() }
                }
                if AudioObjectAddPropertyListenerBlock(current, &running, .main, block) == noErr {
                    runningListener = block
                }
            }
        }
        read()
    }

    private func read() {
        var inUse = false
        var uid: String?
        if let device {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            inUse = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0

            var value: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddress = Self.address(kAudioDevicePropertyDeviceUID)
            if AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &value) == noErr {
                uid = value?.takeRetainedValue() as String?
            }
        }
        isInUse = inUse
        inputUID = uid
        onChange?()
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

// MARK: - Switching

/// Switches a pair to a chosen mode while the Mac is on a call and back afterwards.
///
/// The choice is per pair, since modes differ, and off until one is picked. Only pairs the
/// Mac is using are switched: the default output, or the microphone the call records from.
@MainActor @Observable
final class CallModeSwitch {
    /// The mode for calls, by the pair's address; none means don't switch.
    private(set) var choices: [String: NoiseSetting]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var manager: HeadphonesManager?
    @ObservationIgnored private let microphone = MicrophoneMonitor()
    @ObservationIgnored private var detector = CallDetector()
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Pairs switched for the call in progress, by address.
    @ObservationIgnored private var plans: [String: CallModePlan<NoiseSetting>] = [:]

    private static let key = "callModes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        choices = stored.compactMapValues(NoiseSetting.init(stored:))
    }

    /// The microphone is only watched once a pair has a mode for calls.
    func start(manager: HeadphonesManager) {
        self.manager = manager
        microphone.onChange = { [weak self] in self?.microphoneChanged() }
        if !choices.isEmpty { microphone.start() }
    }

    func setting(for session: HeadphoneSession) -> NoiseSetting? {
        choices[session.address]
    }

    func set(_ setting: NoiseSetting?, for session: HeadphoneSession) {
        choices[session.address] = setting
        defaults.set(choices.mapValues(\.stored), forKey: Self.key)
        if !choices.isEmpty { microphone.start() }
    }

    private func microphoneChanged() {
        settleTask?.cancel()
        guard let deadline = detector.microphone(inUse: microphone.isInUse, at: .now) else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            switch self.detector.settle(at: .now) {
            case .started: self.callStarted()
            case .ended: self.callEnded()
            case nil: break
            }
        }
    }

    private func callStarted() {
        plans = [:]
        for session in manager?.sessions ?? [] {
            // A mode that has since been deleted on the headphones is skipped.
            guard let setting = choices[session.address], isInUse(session),
                  session.noiseOptions.contains(where: { $0.setting == setting }) else { continue }
            var plan = CallModePlan<NoiseSetting>()
            guard let target = plan.callStarted(current: session.currentNoiseSetting, callSetting: setting) else { continue }
            log.info("call started: switching \(session.address, privacy: .public) to \(setting.stored, privacy: .public)")
            plans[session.address] = plan
            session.apply(target)
            watch(session)
        }
    }

    private func callEnded() {
        for (address, var plan) in plans {
            guard let session = manager?.sessions.first(where: { $0.address == address }),
                  let previous = plan.callEnded(current: session.currentNoiseSetting) else { continue }
            log.info("call ended: restoring \(address, privacy: .public) to \(previous.stored, privacy: .public)")
            session.apply(previous)
        }
        plans = [:]
    }

    /// The Mac plays on the pair, or records from its microphone.
    private func isInUse(_ session: HeadphoneSession) -> Bool {
        if manager?.isPlayingHere(session) == true { return true }
        guard let uid = microphone.inputUID else { return false }
        return AudioOutput.bluetoothAddress(fromUID: uid) == AudioOutput.normalized(session.address)
    }

    /// Follows the pair's setting for as long as there's something to put back.
    private func watch(_ session: HeadphoneSession) {
        guard plans[session.address]?.willRestore == true else { return }
        withObservationTracking {
            _ = session.currentMode
            _ = session.anc
        } onChange: { [weak self, weak session] in
            // Fires before the change; read the new value on the next turn.
            Task { @MainActor in
                guard let self, let session else { return }
                self.plans[session.address]?.settingChanged(to: session.currentNoiseSetting)
                self.watch(session)
            }
        }
    }
}
