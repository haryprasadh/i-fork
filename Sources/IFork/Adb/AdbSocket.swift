import Foundation
import Darwin

enum AdbError: LocalizedError {
    case connect(String)
    case io(String)
    case protocolError(String)
    case fail(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connect(let m): return "Can't reach adb: \(m)"
        case .io(let m): return "Connection lost: \(m)"
        case .protocolError(let m): return "Protocol error: \(m)"
        case .fail(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}

/// Blocking TCP socket to the local adb server (127.0.0.1:5037).
/// All calls block; use from background threads only.
final class AdbSocket {
    private var fd: Int32 = -1

    init(port: UInt16 = 5037) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbError.connect("socket() failed") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var buf: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd); fd = -1
            throw AdbError.connect(msg)
        }
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// Unblocks any thread stuck in read/write (used for cancel).
    func shutdownNow() {
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    // MARK: raw I/O

    func write(_ ptr: UnsafeRawPointer, _ count: Int) throws {
        var off = 0
        while off < count {
            let n = Darwin.write(fd, ptr + off, count - off)
            if n < 0 {
                if errno == EINTR { continue }
                throw AdbError.io(String(cString: strerror(errno)))
            }
            off += n
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0.baseAddress!, $0.count) }
    }

    /// Reads exactly `count` bytes into `ptr`.
    func readExact(_ ptr: UnsafeMutableRawPointer, _ count: Int) throws {
        var off = 0
        while off < count {
            let n = Darwin.read(fd, ptr + off, count - off)
            if n < 0 {
                if errno == EINTR { continue }
                throw AdbError.io(String(cString: strerror(errno)))
            }
            if n == 0 { throw AdbError.io("closed by peer") }
            off += n
        }
    }

    func readExact(_ count: Int) throws -> Data {
        var d = Data(count: count)
        if count > 0 { try d.withUnsafeMutableBytes { try readExact($0.baseAddress!, count) } }
        return d
    }

    /// Reads until EOF.
    func readAll() throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw AdbError.io(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    // MARK: adb host protocol

    /// Sends a host-protocol request (4 hex digit length + payload) and waits for OKAY.
    func request(_ service: String) throws {
        let body = Data(service.utf8)
        try write(Data(String(format: "%04x", body.count).utf8) + body)
        try expectOkay()
    }

    func expectOkay() throws {
        let status = String(decoding: try readExact(4), as: UTF8.self)
        if status == "OKAY" { return }
        if status == "FAIL" { throw AdbError.fail(try readHexString()) }
        throw AdbError.protocolError("unexpected status \(status)")
    }

    func readHexString() throws -> String {
        let lenStr = String(decoding: try readExact(4), as: UTF8.self)
        guard let len = Int(lenStr, radix: 16) else { throw AdbError.protocolError("bad length \(lenStr)") }
        return String(decoding: try readExact(len), as: UTF8.self)
    }

    // MARK: little-endian helpers for the sync protocol

    func writeSyncHeader(_ id: String, _ value: UInt32) throws {
        var hdr = Data(id.utf8)
        var le = value.littleEndian
        hdr.append(Data(bytes: &le, count: 4))
        try write(hdr)
    }

    func readSyncHeader() throws -> (String, UInt32) {
        var raw = [UInt8](repeating: 0, count: 8)
        try raw.withUnsafeMutableBytes { try readExact($0.baseAddress!, 8) }
        let id = String(decoding: raw[0..<4], as: UTF8.self)
        let v = UInt32(raw[4]) | UInt32(raw[5]) << 8 | UInt32(raw[6]) << 16 | UInt32(raw[7]) << 24
        return (id, v)
    }
}
