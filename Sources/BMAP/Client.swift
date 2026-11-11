/// Byte pipe to a BMAP device. Implementations deliver callbacks on the main actor.
@MainActor
public protocol BMAPTransport: AnyObject {
    var onReceive: (([UInt8]) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func write(_ bytes: [UInt8]) throws
    func close()
}

/// Request/response layer over a transport.
///
/// Requests are serialized: the device answers in order and replies carry no
/// correlation ID, so only one request is in flight at a time. Packets that
/// don't answer the pending request are delivered to `onNotification`.
@MainActor
public final class BMAPClient {
    public var onNotification: ((Packet) -> Void)?
    public var onClose: (() -> Void)?

    private let transport: BMAPTransport
    private var stream = PacketStream()
    private var pending: Pending?
    private var tail: Task<Void, Never>?
    private var isClosed = false

    private struct Pending {
        let address: Address
        let continuation: CheckedContinuation<Packet, Error>
        let timeout: Task<Void, Never>
    }

    public init(transport: BMAPTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] in self?.receive($0) }
        transport.onClose = { [weak self] in self?.handleClose() }
    }

    /// Sends `packet` and returns the device's reply for the same address.
    /// Throws `BMAPError.device` when the device answers with an error packet.
    public func send(_ packet: Packet, timeout: Duration = .seconds(2)) async throws -> Packet {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await self.perform(packet, timeout: timeout)
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    public func close() {
        transport.close()
        handleClose()
    }

    private func perform(_ packet: Packet, timeout: Duration) async throws -> Packet {
        guard !isClosed else { throw BMAPError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            let address = packet.address
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(BMAPError.timeout(address)))
            }
            pending = Pending(address: address, continuation: continuation, timeout: timer)
            do {
                try transport.write(packet.bytes)
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        for packet in stream.append(bytes) {
            if let pending, pending.address == packet.address, packet.op != .get {
                if packet.op == .error {
                    let code = packet.payload.first.flatMap(DeviceErrorCode.init(rawValue:))
                    finish(.failure(BMAPError.device(packet.address, code)))
                } else {
                    finish(.success(packet))
                }
            } else {
                onNotification?(packet)
            }
        }
    }

    private func finish(_ result: Result<Packet, Error>) {
        guard let p = pending else { return }
        pending = nil
        p.timeout.cancel()
        p.continuation.resume(with: result)
    }

    private func handleClose() {
        guard !isClosed else { return }
        isClosed = true
        stream.reset()
        finish(.failure(BMAPError.disconnected))
        onClose?()
    }
}
