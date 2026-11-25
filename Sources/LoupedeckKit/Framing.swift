import Foundation

// The serial firmware wraps every message in a (binary, masked-with-zeros)
// WebSocket frame, after an HTTP-style "upgrade" handshake.

enum Framing {
    static let upgradeRequest = Array("GET /index.html\nHTTP/1.1\nConnection: Upgrade\nUpgrade: websocket\nSec-WebSocket-Key: 123abc\n\n".utf8)
    static let upgradeResponsePrefix = Array("HTTP/1.1".utf8)
    /// Debug: LOUPEDECK_ZERO_MASK=1 sends payload bytes unmasked so wire bytes are reproducible.
    static let zeroMask = ProcessInfo.processInfo.environment["LOUPEDECK_ZERO_MASK"] != nil
    static let closeFrame: [UInt8] = [0x88, 0x80, 0x00, 0x00, 0x00, 0x00]

    /// Wrap a payload in a binary WebSocket frame, masked with a random key the way a
    /// real WebSocket client does (scottlaird/loupedeck goes through gorilla/websocket).
    /// An all-zero mask sends pixel data through unchanged, and some raw byte patterns
    /// lock up firmware 0.2.5 until it's reconnected.
    static func encode(_ payload: [UInt8], mask: [UInt8]? = nil) -> [UInt8] {
        let mask = mask ?? (zeroMask ? [0, 0, 0, 0] : (0..<4).map { _ in UInt8.random(in: 0...255) })
        var out: [UInt8]
        if payload.count < 126 {
            out = [0x82, 0x80 | UInt8(payload.count)]
        } else {
            out = [0x82, 0xff]
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
            }
        }
        out += mask
        let header = out.count
        out += payload
        out.withUnsafeMutableBufferPointer { buf in
            for i in 0..<payload.count { buf[header + i] ^= mask[i & 3] }
        }
        return out
    }

    /// Build a protocol message: [length, command, transactionID, data...]
    static func message(command: UInt8, transactionID: UInt8, data: [UInt8]) -> [UInt8] {
        [UInt8(min(3 + data.count, 0xff)), command, transactionID] + data
    }
}

/// Incrementally splits the incoming byte stream into WebSocket frame payloads.
struct FrameDecoder {
    private var buffer: [UInt8] = []

    mutating func append(_ bytes: some Sequence<UInt8>) -> [[UInt8]] {
        buffer.append(contentsOf: bytes)
        var frames: [[UInt8]] = []
        while true {
            // Resync: drop anything before the next binary-frame marker.
            guard let start = buffer.firstIndex(of: 0x82) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 2 else { break }

            let masked = buffer[1] & 0x80 != 0
            var length = Int(buffer[1] & 0x7f)
            var header = 2
            if length == 126 {
                guard buffer.count >= 4 else { break }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                header = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { break }
                length = buffer[2..<10].reduce(0) { $0 << 8 | Int($1) }
                header = 10
            }
            var mask: [UInt8] = []
            if masked {
                guard buffer.count >= header + 4 else { break }
                mask = Array(buffer[header..<header + 4])
                header += 4
            }
            guard buffer.count >= header + length else { break }
            var payload = Array(buffer[header..<header + length])
            if masked {
                for i in payload.indices { payload[i] ^= mask[i % 4] }
            }
            frames.append(payload)
            buffer.removeFirst(header + length)
        }
        return frames
    }
}
