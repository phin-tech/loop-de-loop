import Darwin
import Foundation

public enum SerialPortError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case configure(errno: Int32)
    case write(errno: Int32)
    case closed

    public var description: String {
        switch self {
        case .open(let path, let e): "Could not open \(path): \(String(cString: strerror(e)))"
        case .configure(let e): "Could not configure serial port: \(String(cString: strerror(e)))"
        case .write(let e): "Serial write failed: \(String(cString: strerror(e)))"
        case .closed: "Serial port is closed"
        }
    }
}

/// Minimal raw POSIX serial port. Reads are delivered on `queue` via a dispatch source.
final class SerialPort: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let writeLock = NSLock()
    private var source: DispatchSourceRead?
    private var isClosed = false

    /// `_IOW('T', 2, speed_t)` — lets macOS use non-standard baud rates.
    private static let IOSSIOSPEED: UInt = 0x8008_5402

    init(path: String, baudRate: Int = 256_000) throws {
        self.path = path
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError.open(path: path, errno: errno) }
        self.fd = fd

        // Exclusive access so the Loupedeck app (or a second copy of us) can't fight over it.
        _ = ioctl(fd, TIOCEXCL)

        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { Darwin.close(fd); throw SerialPortError.configure(errno: errno) }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { Darwin.close(fd); throw SerialPortError.configure(errno: errno) }

        var speed = speed_t(baudRate)
        _ = ioctl(fd, Self.IOSSIOSPEED, &speed) // USB CDC ignores this; harmless if it fails.

        // Blocking writes; reads are driven by the dispatch source.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    /// Start delivering reads. `onData` receives an empty array on EOF/error.
    func startReading(on queue: DispatchQueue, onData: @escaping ([UInt8]) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onData(Array(buf[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                onData([])
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source
        source.resume()
    }

    func write(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw SerialPortError.closed }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, bytes.count - offset)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialPortError.write(errno: errno)
            }
            offset += n
        }
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        if let source {
            source.cancel() // closes fd
        } else {
            Darwin.close(fd)
        }
    }
}
