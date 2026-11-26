import Foundation

/// One adb "sync:" session on a device transport. Reusable for many files, one at a time.
/// Uses sync v1 (no compression): fastest for photos/videos, which don't compress.
final class AdbSync {
    private let sock: AdbSocket
    private static let chunk = 64 * 1024 // SYNC_DATA_MAX

    init(serial: String) throws {
        sock = try AdbClient.open(serial)
        try sock.request("sync:")
    }

    deinit { quit() }

    func quit() {
        try? sock.writeSyncHeader("QUIT", 0)
        sock.close()
    }

    func abort() { sock.shutdownNow() }

    private func sendRequest(_ id: String, _ path: String) throws {
        let p = Data(path.utf8)
        try sock.writeSyncHeader(id, UInt32(p.count))
        try sock.write(p)
    }

    /// Phone -> Mac. Streams straight into `local` (created/truncated). `progress` gets byte deltas.
    func pull(_ remote: String, to local: URL, progress: (Int) -> Void, isCancelled: () -> Bool) throws {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = local.appendingPathExtension("ifpart")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: part.path) else {
            throw AdbError.io("can't write \(local.path)")
        }
        var ok = false
        defer {
            try? fh.close()
            if !ok { try? FileManager.default.removeItem(at: part) }
        }

        try sendRequest("RECV", remote)
        // Accumulate several 64 KB packets before each disk write.
        let bufCap = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufCap, alignment: 16)
        defer { buf.deallocate() }
        var filled = 0
        func flush() throws {
            if filled > 0 { try fh.write(contentsOf: Data(bytesNoCopy: buf, count: filled, deallocator: .none)); filled = 0 }
        }
        while true {
            if isCancelled() { throw AdbError.cancelled }
            let (id, len) = try sock.readSyncHeader()
            switch id {
            case "DATA":
                let n = Int(len)
                if filled + n > bufCap { try flush() }
                try sock.readExact(buf + filled, n)
                filled += n
                progress(n)
            case "DONE":
                try flush()
                try fh.close()
                if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
                try FileManager.default.moveItem(at: part, to: local)
                ok = true
                return
            case "FAIL":
                throw AdbError.fail(String(decoding: try sock.readExact(Int(len)), as: UTF8.self))
            default:
                throw AdbError.protocolError("unexpected \(id) during pull")
            }
        }
    }

    /// Mac -> Phone. Parent folders are created by adbd.
    func push(_ local: URL, to remote: String, progress: (Int) -> Void, isCancelled: () -> Bool) throws {
        guard let fh = FileHandle(forReadingAtPath: local.path) else { throw AdbError.io("can't read \(local.path)") }
        defer { try? fh.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: local.path)
        let mtime = UInt32((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)

        try sendRequest("SEND", "\(remote),\(0o100644)")
        // Read 1 MB at a time and send it as 16 DATA frames in ONE socket write.
        // adb acks each transport packet, so big writes = far fewer round trips.
        let readSize = 16 * AdbSync.chunk
        var batch = Data(capacity: readSize + 16 * 8)
        let tag = Array("DATA".utf8)
        while true {
            if isCancelled() { throw AdbError.cancelled }
            guard let data = try fh.read(upToCount: readSize), !data.isEmpty else { break }
            batch.removeAll(keepingCapacity: true)
            var off = 0
            while off < data.count {
                let n = min(AdbSync.chunk, data.count - off)
                batch.append(contentsOf: tag)
                var le = UInt32(n).littleEndian
                withUnsafeBytes(of: &le) { batch.append(contentsOf: $0) }
                batch.append(data[data.startIndex + off ..< data.startIndex + off + n])
                off += n
            }
            try sock.write(batch)
            progress(data.count)
        }
        try sock.writeSyncHeader("DONE", mtime)
        let (id, len) = try sock.readSyncHeader()
        if id == "OKAY" { return }
        if id == "FAIL" { throw AdbError.fail(String(decoding: try sock.readExact(Int(len)), as: UTF8.self)) }
        throw AdbError.protocolError("unexpected \(id) after push")
    }
}
