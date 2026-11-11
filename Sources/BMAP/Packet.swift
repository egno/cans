/// BMAP (Bose Messaging and Protocol) framing.
///
/// Wire format: `[fblock, function, flags, length, payload...]`, where the low
/// nibble of `flags` is the operator.

public enum Operator: UInt8, Sendable {
    case set = 0, get = 1, setGet = 2, status = 3, error = 4, start = 5, result = 6, processing = 7
}

public struct Address: Hashable, Sendable, CustomStringConvertible {
    public let fblock: UInt8
    public let function: UInt8

    public init(_ fblock: UInt8, _ function: UInt8) {
        self.fblock = fblock
        self.function = function
    }

    public var description: String { "[\(fblock).\(function)]" }
}

public struct Packet: Equatable, Sendable, CustomStringConvertible {
    public let address: Address
    public let op: Operator
    public let payload: [UInt8]

    public init(_ address: Address, _ op: Operator, _ payload: [UInt8] = []) {
        precondition(payload.count <= 255, "BMAP payload too long")
        self.address = address
        self.op = op
        self.payload = payload
    }

    public var bytes: [UInt8] {
        [address.fblock, address.function, op.rawValue, UInt8(payload.count)] + payload
    }

    public var description: String {
        "\(address) \(op) \(payload.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined())"
    }
}

/// Reassembles packets from an RFCOMM byte stream, which may split or merge frames.
public struct PacketStream: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [Packet] {
        buffer += bytes
        var packets: [Packet] = []
        while buffer.count >= 4 {
            let length = Int(buffer[3])
            guard buffer.count >= 4 + length else { break }
            if let op = Operator(rawValue: buffer[2] & 0x0F) {
                packets.append(Packet(Address(buffer[0], buffer[1]), op, Array(buffer[4..<4 + length])))
            }
            buffer.removeFirst(4 + length)
        }
        return packets
    }

    public mutating func reset() { buffer = [] }
}

/// Error codes carried in the payload of an `.error` packet.
public enum DeviceErrorCode: UInt8, Sendable {
    case unknown = 0, length, checksum, fblockNotSupported, functionNotSupported,
         operatorNotSupported, invalidData, dataUnavailable, runtime, timeout, invalidState
    case invalidTransition = 15
    case insecureTransport = 20
}

public enum BMAPError: Error, Equatable, Sendable {
    case device(Address, DeviceErrorCode?)
    case timeout(Address)
    case disconnected
    case malformed(Address)
}
