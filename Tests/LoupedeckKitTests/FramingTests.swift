import Testing
@testable import LoupedeckKit

@Suite struct FramingTests {
    @Test func smallFrameRoundTrips() {
        let payload: [UInt8] = [0x05, 0x07, 0x01, 0xaa, 0xbb]
        let frame = Framing.encode(payload, mask: [1, 2, 3, 4])
        #expect(frame[0] == 0x82)
        #expect(frame[1] == 0x80 | 5)
        var d = FrameDecoder()
        #expect(d.append(frame) == [payload])
    }

    @Test func largeFrameUsesExtendedLengthAndRoundTrips() {
        let payload = (0..<16_213).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let frame = Framing.encode(payload, mask: [0x2e, 0xa3, 0x93, 0xba])
        #expect(frame[1] == 0xff)
        #expect(frame.count == 14 + payload.count)
        var d = FrameDecoder()
        #expect(d.append(frame) == [payload])
    }

    @Test func randomMaskChangesWireBytes() {
        let payload = [UInt8](repeating: 0x27, count: 200)
        let a = Framing.encode(payload, mask: [9, 9, 9, 9]), b = Framing.encode(payload, mask: [0, 0, 0, 0])
        #expect(Array(a.suffix(200)) != payload)
        #expect(Array(b.suffix(200)) == payload)
    }

    @Test func decoderHandlesSplitAndBackToBackFrames() {
        let f1 = Framing.encode([1, 2, 3], mask: [0, 0, 0, 0])
        let f2 = Framing.encode([4, 5], mask: [7, 7, 7, 7])
        let stream = f1 + f2
        var d = FrameDecoder()
        var out: [[UInt8]] = []
        for byte in stream { out += d.append([byte]) }
        #expect(out == [[1, 2, 3], [4, 5]])
    }

    @Test func touchTargetsMatchLiveLayout() {
        let m = LoupedeckModel.live
        #expect(m.target(x: 30, y: 100) == .strip(.left))
        #expect(m.target(x: 450, y: 100) == .strip(.right))
        #expect(m.target(x: 106, y: 48) == .key(0))
        #expect(m.target(x: 348, y: 71) == .key(3))
        #expect(m.target(x: 61, y: 160) == .key(4))
        #expect(m.target(x: 340, y: 269) == .key(11))
    }
}
