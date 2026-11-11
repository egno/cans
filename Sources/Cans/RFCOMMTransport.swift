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

/// BMAP over a classic Bluetooth RFCOMM channel (channel 2 on Bose headphones).
///
/// Only the RFCOMM channel is opened and closed; the baseband (audio) link is
/// never touched, so closing this never disconnects the headphones.
@MainActor
final class RFCOMMTransport: NSObject, BMAPTransport {
    static let bmapChannel: BluetoothRFCOMMChannelID = 2

    var onReceive: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?

    let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening: CheckedContinuation<Void, Error>?

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    func open(timeout: Duration = .seconds(8)) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            opening = cont
            var ch: IOBluetoothRFCOMMChannel?
            let status = device.openRFCOMMChannelAsync(&ch, withChannelID: Self.bmapChannel, delegate: self)
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
