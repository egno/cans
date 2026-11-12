import BMAP
import IOBluetooth

enum TransportError: Error, CustomStringConvertible {
    case open(IOReturn)
    case openTimeout
    case write(IOReturn)
    case notOpen

    var description: String {
        switch self {
        case .open(let s): "RFCOMM open failed (\(String(format: "0x%08x", s)))"
        case .openTimeout: "RFCOMM open timed out"
        case .write(let s): "RFCOMM write failed (\(String(format: "0x%08x", s)))"
        case .notOpen: "RFCOMM channel not open"
        }
    }
}

/// BMAP over a classic Bluetooth RFCOMM channel. The channel differs by model
/// (2 on QC Ultra, 8 on QC35 II); `BMAPService` finds it.
///
/// Only the RFCOMM channel is opened and closed; the baseband (audio) link is
/// never touched, so closing this never disconnects the headphones.
@MainActor
final class RFCOMMTransport: NSObject, BMAPTransport {
    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    let device: IOBluetoothDevice
    let channelID: BluetoothRFCOMMChannelID
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void, Error>?

    init(device: IOBluetoothDevice, channel: BluetoothRFCOMMChannelID) {
        self.device = device
        self.channelID = channel
    }

    func open(timeout: Duration = .seconds(8)) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            opening = cont
            var ch: IOBluetoothRFCOMMChannel?
            let status = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
            guard status == kIOReturnSuccess, let ch else {
                finishOpen(.failure(TransportError.open(status)))
                return
            }
            channel = ch
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishOpen(.failure(TransportError.openTimeout))
            }
        }
    }

    func write(_ bytes: [UInt8]) throws {
        guard let channel else { throw TransportError.notOpen }
        var buf = bytes
        let status = channel.writeSync(&buf, length: UInt16(buf.count))
        guard status == kIOReturnSuccess else { throw TransportError.write(status) }
    }

    func close() {
        let ch = channel
        channel = nil
        _ = ch?.close()
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        guard let cont = opening else { return }
        opening = nil
        if case .failure = result { close() }
        cont.resume(with: result)
    }

    fileprivate func channelOpened(_ status: IOReturn) {
        finishOpen(status == kIOReturnSuccess ? .success(()) : .failure(TransportError.open(status)))
    }

    fileprivate func channelClosed() {
        channel = nil
        finishOpen(.failure(TransportError.notOpen))
        onClose?()
    }
}

// IOBluetooth calls these on the run loop that opened the channel: the main thread.
extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated { channelOpened(error) }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                       data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { onReceive?(bytes) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated { channelClosed() }
    }
}

// MARK: - Finding the channel

/// Where a paired device offers BMAP, from its SDP records.
///
/// On Bose headphones BMAP is the record with the Serial Port UUID (QC Ultra
/// "SPPS De" on channel 2, QC35 II "SPP Dev" on channel 8). Not the
/// 00000000-deca-fade-deca-deafdecacaff record: that's iAP.
@MainActor
enum BMAPService {
    static let serialPortUUID: BluetoothSDPUUID16 = 0x1101
    static let pnpInformationUUID: BluetoothSDPUUID16 = 0x1200
    /// Bluetooth SIG company identifier.
    static let boseVendorID = 0x009E

    /// Channels to try, best first; empty when the device clearly isn't Bose.
    static func channels(for device: IOBluetoothDevice, query: SDPQuery) async -> [UInt8] {
        // macOS caches the records at pairing; ask the device only when there are none.
        if (device.services ?? []).isEmpty {
            _ = await query.run(on: device)
        }
        // Checked before the serial port record: BMAP bytes must never reach another
        // vendor's serial port.
        if let vendor = vendorID(of: device), vendor != boseVendorID { return [] }
        if let channel = channel(of: device) { return [channel] }
        return ModelRegistry.knownChannels
    }

    static func channel(of device: IOBluetoothDevice) -> UInt8? {
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: serialPortUUID)) else { return nil }
        var id: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess, id != 0 else { return nil }
        return id
    }

    /// VendorID from the Device ID (PnP Information) record, when the device has one cached.
    static func vendorID(of device: IOBluetoothDevice) -> Int? {
        device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: pnpInformationUUID))?
            .getAttributeDataElement(0x0201)?.getNumberValue()?.intValue
    }
}

/// Runs SDP queries. Long-lived, because IOBluetooth calls back on its target
/// even after we've stopped waiting.
///
/// The completion carries no query ID, so a device gets no new query until the
/// previous one has called back (or is long overdue); any completion then
/// belongs to the one query in flight.
@MainActor
final class SDPQuery: NSObject {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }

    private var waiting: [String: Waiter] = [:]
    /// Queries started and not yet called back, by address.
    private var inFlight: [String: ContinuousClock.Instant] = [:]
    /// After this a query that never called back is forgotten.
    private static let overdue: Duration = .seconds(60)

    /// True when the device answered with fresh records.
    func run(on device: IOBluetoothDevice, timeout: Duration = .seconds(10)) async -> Bool {
        let key = device.addressString ?? ""
        if let started = inFlight[key], .now - started < Self.overdue { return false }
        return await withCheckedContinuation { cont in
            guard device.performSDPQuery(self) == kIOReturnSuccess else {
                cont.resume(returning: false)
                return
            }
            inFlight[key] = .now
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(key, false)
            }
            waiting[key] = Waiter(continuation: cont, timer: timer)
        }
    }

    private func finish(_ key: String, _ ok: Bool) {
        guard let waiter = waiting.removeValue(forKey: key) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: ok)
    }

    private func completed(_ key: String, _ ok: Bool) {
        // Not ours, or a stale one that was already forgotten.
        guard inFlight.removeValue(forKey: key) != nil else { return }
        finish(key, ok)
    }

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let key = device?.addressString ?? ""
        MainActor.assumeIsolated { completed(key, status == kIOReturnSuccess) }
    }
}

/// Brings up the baseband link to a paired device, the way connecting it in Bluetooth
/// settings does, so a pair that's on but not linked can be probed. Long-lived for the
/// same reason as `SDPQuery`; one attempt per device at a time.
@MainActor
final class LinkOpener: NSObject {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }

    private var waiting: [String: Waiter] = [:]

    /// True once the link is up.
    func open(_ device: IOBluetoothDevice, timeout: Duration = .seconds(15)) async -> Bool {
        if device.isConnected() { return true }
        let key = device.addressString ?? ""
        guard waiting[key] == nil else { return false }
        return await withCheckedContinuation { cont in
            guard device.openConnection(self) == kIOReturnSuccess else {
                cont.resume(returning: false)
                return
            }
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(key, false)
            }
            waiting[key] = Waiter(continuation: cont, timer: timer)
        }
    }

    private func finish(_ key: String, _ ok: Bool) {
        guard let waiter = waiting.removeValue(forKey: key) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: ok)
    }

    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        let key = device?.addressString ?? ""
        MainActor.assumeIsolated { finish(key, status == kIOReturnSuccess) }
    }
}
