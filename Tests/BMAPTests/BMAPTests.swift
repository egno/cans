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

    @Test func failsPendingOnClose() async {
        let t = FakeTransport()
        let c = BMAPClient(transport: t)
        Task { @MainActor in t.onClose?() }
        await #expect(throws: BMAPError.disconnected) {
            try await c.send(Request.get(.battery))
        }
    }
}
