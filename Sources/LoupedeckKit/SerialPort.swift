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
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var _isClosed = false
    private var isClosed: Bool { stateLock.withLock { _isClosed } }

    /// How long a single write may wait for the device to accept data.
    static let writeTimeout: TimeInterval = 2

    /// `_IOW('T', 2, speed_t)` — lets macOS use non-standard baud rates.
    private static let IOSSIOSPEED: UInt = 0x8008_5402

    init(path: String, baudRate: Int = 256_000) throws {
        self.path = path
        // A previous handle closes asynchronously (dispatch cancel handler), so the exclusive
        // lock can still be held for a moment right after a reconnect. Retry briefly on EBUSY.
        var fd: Int32 = -1
        for attempt in 0..<25 {
            fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            if fd >= 0 || errno != EBUSY || attempt == 24 { break }
            usleep(20_000)
        }
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

        // Stays non-blocking: reads are driven by the dispatch source, and writes poll with
        // a deadline so a device that stops reading can't block close() forever.
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
        let deadline = Date().addingTimeInterval(Self.writeTimeout)
        var offset = 0
        while offset < bytes.count {
            guard !isClosed else { throw SerialPortError.closed }
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, bytes.count - offset)
            }
            if n >= 0 {
                offset += n
                continue
            }
            guard errno == EAGAIN || errno == EINTR else { throw SerialPortError.write(errno: errno) }
            guard Date() < deadline else { throw SerialPortError.write(errno: ETIMEDOUT) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 100)
        }
    }

    func close() {
        let shouldClose: Bool = stateLock.withLock {
            defer { _isClosed = true }
            return !_isClosed
        }
        guard shouldClose else { return }
        // Discard unsent output so a pending write (and the kernel's drain-on-close) can't hang.
        tcflush(fd, TCIOFLUSH)
        // Any in-flight write sees isClosed within one poll slice; wait for it before closing the fd.
        writeLock.lock()
        defer { writeLock.unlock() }
        if let source {
            source.cancel() // closes fd
        } else {
            Darwin.close(fd)
        }
    }
}
