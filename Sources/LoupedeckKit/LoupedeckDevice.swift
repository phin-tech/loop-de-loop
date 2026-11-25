import CoreGraphics
import Foundation

public enum LoupedeckError: Error, CustomStringConvertible {
    case noDeviceFound
    case handshakeFailed(String)
    case timeout(Command)
    case disconnected
    case invalidKey(Int)

    public var description: String {
        switch self {
        case .noDeviceFound: "No Loupedeck found"
        case .handshakeFailed(let s): "Handshake failed: \(s)"
        case .timeout(let c): "Timed out waiting for response to \(c)"
        case .disconnected: "Device disconnected"
        case .invalidKey(let k): "Invalid key index \(k)"
        }
    }
}

/// A connected Loupedeck Live-family device (serial firmware 0.2.x).
///
/// All internal state lives on a private serial queue. Writes go through a
/// second queue so large framebuffer uploads never stall event handling.
public final class LoupedeckDevice: @unchecked Sendable {
    public let path: String
    public let model: LoupedeckModel
    public let events: AsyncStream<LoupedeckEvent>

    private let port: SerialPort
    private let queue = DispatchQueue(label: "LoupedeckKit.io")
    private let writeQueue = DispatchQueue(label: "LoupedeckKit.write")
    private let eventSink: AsyncStream<LoupedeckEvent>.Continuation

    // Guarded by `queue`.
    private var decoder = FrameDecoder()
    private var handshake: [UInt8] = []
    private var handshakeWaiter: CheckedContinuation<Void, Error>?
    private var connected = false
    private var transactionID: UInt8 = 0
    private var pending: [UInt8: CheckedContinuation<[UInt8], Error>] = [:]
    private var activeTouches: Set<UInt8> = []

    /// Connect to the first Loupedeck found.
    public static func connect() async throws -> LoupedeckDevice {
        guard let found = Discovery.devices().first(where: { $0.model != nil }) else {
            throw LoupedeckError.noDeviceFound
        }
        return try await connect(path: found.path, model: found.model ?? .live)
    }

    public static func connect(path: String, model: LoupedeckModel = .live) async throws -> LoupedeckDevice {
        let device = try LoupedeckDevice(path: path, model: model)
        do {
            try await device.performHandshake()
        } catch {
            device.close()
            throw error
        }
        return device
    }

    private init(path: String, model: LoupedeckModel) throws {
        self.path = path
        self.model = model
        self.port = try SerialPort(path: path)
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    // The last reference can drop inside a block on `queue`, so deinit must not `queue.sync`.
    deinit {
        eventSink.finish()
        port.close()
    }

    public func close() {
        queue.sync {
            guard connected || handshakeWaiter != nil else { return }
            try? port.write(Framing.closeFrame)
            teardown()
        }
        port.close()
    }

    // MARK: - Public API

    public var isConnected: Bool { queue.sync { connected } }

    public func serialNumber() async throws -> String {
        let data = try await request(.serial)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    public func firmwareVersion() async throws -> String {
        let data = try await request(.version)
        guard data.count >= 3 else { return data.map(String.init).joined(separator: ".") }
        return "\(data[0]).\(data[1]).\(data[2])"
    }

    /// Brightness from 0 (off) to 1 (max).
    public func setBrightness(_ value: Double) async throws {
        let level = UInt8(max(0, min(Double(maxBrightness), (value * Double(maxBrightness)).rounded())))
        try await send(.setBrightness, [level])
    }

    public func setButtonColor(_ button: Int, red: UInt8, green: UInt8, blue: UInt8) async throws {
        guard let id = Control.button(button).wireID else { throw LoupedeckError.invalidKey(button) }
        try await send(.setColor, [id, red, green, blue])
    }

    public func vibrate(_ pattern: Haptic = .short) async throws {
        try await send(.setVibration, [pattern.rawValue])
    }

    /// Upload RGB565-LE pixels to a framebuffer region, then optionally refresh the display.
    public func drawPixels(x: Int, y: Int, width: Int, height: Int, rgb565: [UInt8], refresh: Bool = true) async throws {
        precondition(rgb565.count == width * height * 2, "Expected \(width * height * 2) bytes, got \(rgb565.count)")
        var payload = LoupedeckModel.displayID
        for v in [x, y, width, height] { payload += [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        payload += rgb565
        // Firmware 0.2.5 acks every framebuffer write within milliseconds; a missing ack
        // means the device has wedged, so surface it (LoupedeckError.timeout) for recovery.
        _ = try await request(.framebuffer, payload, timeout: Self.drawAckTimeout)
        if refresh { try await self.refresh() }
    }

    /// Push the framebuffer to the panel.
    public func refresh() async throws {
        _ = try await request(.draw, LoupedeckModel.displayID, timeout: Self.drawAckTimeout)
    }

    public func drawKey(_ index: Int, image: CGImage, refresh: Bool = true) async throws {
        guard (0..<model.keyCount).contains(index) else { throw LoupedeckError.invalidKey(index) }
        let r = model.rect(forKey: index)
        try await drawPixels(x: r.x, y: r.y, width: r.width, height: r.height,
                             rgb565: RGB565.encode(image, width: r.width, height: r.height), refresh: refresh)
    }

    public func drawKey(_ index: Int, refresh: Bool = true, draw: (CGContext) -> Void) async throws {
        guard (0..<model.keyCount).contains(index) else { throw LoupedeckError.invalidKey(index) }
        let r = model.rect(forKey: index)
        try await drawPixels(x: r.x, y: r.y, width: r.width, height: r.height,
                             rgb565: RGB565.encode(width: r.width, height: r.height, draw: draw), refresh: refresh)
    }

    public func drawStrip(_ strip: Strip, image: CGImage, refresh: Bool = true) async throws {
        let r = model.rect(for: strip)
        guard r.width > 0 else { return }
        try await drawPixels(x: r.x, y: r.y, width: r.width, height: r.height,
                             rgb565: RGB565.encode(image, width: r.width, height: r.height), refresh: refresh)
    }

    public func drawStrip(_ strip: Strip, refresh: Bool = true, draw: (CGContext) -> Void) async throws {
        let r = model.rect(for: strip)
        guard r.width > 0 else { return }
        try await drawPixels(x: r.x, y: r.y, width: r.width, height: r.height,
                             rgb565: RGB565.encode(width: r.width, height: r.height, draw: draw), refresh: refresh)
    }

    /// Draw the whole 480×270 screen at once.
    public func drawScreen(image: CGImage) async throws {
        try await drawPixels(x: 0, y: 0, width: model.screenWidth, height: model.screenHeight,
                             rgb565: RGB565.encode(image, width: model.screenWidth, height: model.screenHeight))
    }

    // MARK: - Debugging

    private var lastLargeFrame: [UInt8] = []

    /// Wire bytes of the most recent large (framebuffer) frame, for diagnosing firmware hangs.
    public func debugLastLargeFrame() -> [UInt8] { queue.sync { lastLargeFrame } }

    /// Write bytes straight to the port, outside any frame.
    public func debugWriteRaw(_ bytes: [UInt8]) throws { try port.write(bytes) }

    // MARK: - Transactions

    /// How long to wait for a draw ack before treating the device as wedged.
    public static let drawAckTimeout: TimeInterval = 1

    /// Send a command and wait for the device to acknowledge it. Missing acks are
    /// tolerated (some firmware versions don't ack every command).
    public func send(_ command: Command, _ data: [UInt8] = []) async throws {
        do {
            _ = try await request(command, data)
        } catch LoupedeckError.timeout {
            // Ignore: the write went out.
        }
    }

    /// Send a command and return the response payload.
    public func request(_ command: Command, _ data: [UInt8] = [], timeout: TimeInterval = 2) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            queue.async { [self] in
                guard connected else { return cont.resume(throwing: LoupedeckError.disconnected) }
                transactionID = transactionID == 255 ? 1 : transactionID + 1 // device ignores ID 0
                let tid = transactionID
                pending.removeValue(forKey: tid)?.resume(throwing: LoupedeckError.timeout(command))
                pending[tid] = cont
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    pending.removeValue(forKey: tid)?.resume(throwing: LoupedeckError.timeout(command))
                }
                let frame = Framing.encode(Framing.message(command: command.rawValue, transactionID: tid, data: data))
                if Self.trace {
                    FileHandle.standardError.write(Data(("tx " + frame.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " ") + " (\(frame.count) bytes)\n").utf8))
                }
                if frame.count > 1024 { lastLargeFrame = frame }
                writeQueue.async { [self] in
                    do {
                        try port.write(frame)
                    } catch {
                        queue.async { [self] in pending.removeValue(forKey: tid)?.resume(throwing: error) }
                    }
                }
            }
        }
    }

    // MARK: - Connection

    private func performHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                handshakeWaiter = cont
                port.startReading(on: queue) { [weak self] bytes in self?.receive(bytes) }
                do {
                    try port.write(Framing.upgradeRequest)
                } catch {
                    return finishHandshake(.failure(error))
                }
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    finishHandshake(.failure(LoupedeckError.handshakeFailed(
                        handshake.isEmpty ? "no response" : String(decoding: handshake, as: UTF8.self))))
                }
            }
        }
    }

    private func finishHandshake(_ result: Result<Void, Error>) {
        guard let waiter = handshakeWaiter else { return }
        handshakeWaiter = nil
        if case .success = result { connected = true }
        waiter.resume(with: result)
    }

    private func receive(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return teardown() }

        if !connected {
            handshake += bytes
            guard handshake.count >= Framing.upgradeResponsePrefix.count else { return }
            guard handshake.starts(with: Framing.upgradeResponsePrefix) else {
                return finishHandshake(.failure(LoupedeckError.handshakeFailed(String(decoding: handshake, as: UTF8.self))))
            }
            // Headers end in a blank line; anything after that is frame data.
            for terminator in ["\r\n\r\n", "\n\n"].map({ Array($0.utf8) }) {
                if let end = handshake.firstRange(of: terminator)?.upperBound {
                    let rest = Array(handshake[end...])
                    finishHandshake(.success(()))
                    if !rest.isEmpty { process(rest) }
                    return
                }
            }
            // No terminator yet: give the device a moment, then accept what we have.
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in finishHandshake(.success(())) }
            return
        }
        process(bytes)
    }

    private static let trace = ProcessInfo.processInfo.environment["LOUPEDECK_TRACE"] != nil

    private func process(_ bytes: [UInt8]) {
        if Self.trace {
            FileHandle.standardError.write(Data(("rx " + bytes.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ") + "\n").utf8))
        }
        for frame in decoder.append(bytes) { handle(message: frame) }
    }

    private func handle(message: [UInt8]) {
        guard message.count >= 3 else { return }
        let length = Int(message[0])
        let command = message[1]
        let tid = message[2]
        let data = Array(message[3..<max(3, min(length, message.count))])

        switch Command(rawValue: command) {
        case .buttonPress where data.count >= 2:
            if let control = Control(wireID: data[0]) {
                eventSink.yield(data[1] == 0 ? .pressed(control) : .released(control))
            }
        case .knobRotate where data.count >= 2:
            if let knob = Knob(wireID: data[0]) {
                eventSink.yield(.rotated(knob, delta: Int(Int8(bitPattern: data[1]))))
            }
        case .touch, .touchCT:
            if let touch = parseTouch(data) {
                let isNew = activeTouches.insert(touch.id).inserted
                eventSink.yield(isNew ? .touchBegan(touch) : .touchMoved(touch))
            }
        case .touchEnd, .touchEndCT:
            if let touch = parseTouch(data) {
                activeTouches.remove(touch.id)
                eventSink.yield(.touchEnded(touch))
            }
        default:
            break
        }

        if tid != 0, let waiter = pending.removeValue(forKey: tid) {
            waiter.resume(returning: data)
        }
    }

    private func parseTouch(_ data: [UInt8]) -> Touch? {
        guard data.count >= 6 else { return nil }
        let x = Int(data[1]) << 8 | Int(data[2])
        let y = Int(data[3]) << 8 | Int(data[4])
        // foxxyz uses byte 5 as the touch ID, but on firmware 0.2.5 it drifts mid-touch;
        // byte 0 is the stable finger slot.
        return Touch(id: data[0], x: x, y: y, target: model.target(x: x, y: y), pressure: data[5])
    }

    private func teardown() {
        let wasConnected = connected
        connected = false
        finishHandshake(.failure(LoupedeckError.disconnected))
        for (_, waiter) in pending { waiter.resume(throwing: LoupedeckError.disconnected) }
        pending.removeAll()
        if wasConnected { eventSink.yield(.disconnected) }
        eventSink.finish()
        port.close()
    }
}
