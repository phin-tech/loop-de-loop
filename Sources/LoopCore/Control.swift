import Darwin
import Foundation

/// A command for the running app. The CLI, the `loopdeloop://` URL scheme, and the
/// socket all produce this. Positional arguments are stored as "0", "1", …
///
///   loopctl set-key 3 --title Hi --bg ff0000
///   open -g 'loopdeloop://set-key/3?title=Hi&bg=ff0000'
public struct ControlRequest: Codable, Sendable, Equatable {
    public var command: String
    public var args: [String: String]

    public init(command: String, args: [String: String] = [:]) {
        self.command = command
        self.args = args
    }

    public func positional(_ i: Int) -> String? { args[String(i)] }

    /// Options that never take a value, so `--all file.json` keeps file.json positional.
    public static let booleanFlags: Set<String> = ["all", "persist"]

    /// Parse CLI-style arguments: `cmd pos0 pos1 --key value --flag`.
    public init?(arguments: [String]) {
        guard let command = arguments.first else { return nil }
        self.command = command
        var args: [String: String] = [:]
        var position = 0
        var it = arguments.dropFirst().makeIterator()
        var pendingKey: String?
        while let a = it.next() {
            if a.hasPrefix("--") {
                if let k = pendingKey { args[k] = "true" }
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    args[String(body[..<eq])] = String(body[body.index(after: eq)...])
                    pendingKey = nil
                } else if Self.booleanFlags.contains(body) {
                    args[body] = "true"
                } else {
                    pendingKey = body
                }
            } else if let k = pendingKey {
                args[k] = a
                pendingKey = nil
            } else {
                args[String(position)] = a
                position += 1
            }
        }
        if let k = pendingKey { args[k] = "true" }
        self.args = args
    }

    /// Parse `loopdeloop://command/pos0/pos1?key=value`.
    public init?(url: URL) {
        guard url.scheme == "loopdeloop", let host = url.host(), !host.isEmpty else { return nil }
        command = host
        var args: [String: String] = [:]
        for (i, part) in url.pathComponents.filter({ $0 != "/" }).enumerated() { args[String(i)] = part }
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            args[item.name] = item.value ?? "true"
        }
        self.args = args
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var message: String
    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
    public static func ok(_ m: String = "ok") -> ControlResponse { .init(ok: true, message: m) }
    public static func error(_ m: String) -> ControlResponse { .init(ok: false, message: m) }
}

// MARK: - Socket server (in the app)

/// Line-delimited JSON over a Unix domain socket: one request, one response per connection.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse
    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1

    public init(path: String = Paths.controlSocket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ActionError(description: "socket: \(String(cString: strerror(errno)))") }
        var addr = try Self.address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw ActionError(description: "bind \(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        listenFD = fd
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "LoopDeLoop.control"
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global().async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = Self.readLine(fd),
              let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            Self.reply(fd, .error("bad request"))
            return
        }
        let handler = self.handler
        Task {
            let response = await handler(request)
            Self.reply(fd, response)
        }
    }

    static func reply(_ fd: Int32, _ response: ControlResponse) {
        var data = (try? JSONEncoder().encode(response)) ?? Data()
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let nl = data.firstIndex(of: 0x0a) { return data[..<nl] }
        }
        return data.isEmpty ? nil : data
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw ActionError(description: "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}

// MARK: - Client (the CLI)

public enum ControlClient {
    public static func send(_ request: ControlRequest, path: String = Paths.controlSocket.path,
                            timeout: Int = 15) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ActionError(description: "socket failed") }
        defer { close(fd) }
        var addr = try ControlServer.address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw ActionError(description: "LoopDeLoop isn't running (no socket at \(path))") }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard let line = ControlServer.readLine(fd) else { throw ActionError(description: "no response from LoopDeLoop") }
        return try JSONDecoder().decode(ControlResponse.self, from: line)
    }
}
