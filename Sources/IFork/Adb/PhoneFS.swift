import Foundation

struct PhoneEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
}

/// File operations on the phone over an adb transport (shell `find` + `stat`, 64-bit sizes).
enum PhoneFS {
    static let root = "/sdcard"

    /// Lists one folder. Follows symlinks so /sdcard-style links show as folders.
    static func list(_ serial: String, _ dir: String) throws -> [PhoneEntry] {
        let d = dir.hasSuffix("/") ? dir : dir + "/"
        let out = try AdbClient.exec(serial,
            "find \(d.shQuoted) -mindepth 1 -maxdepth 1 -exec stat -L -c '%f|%s|%Y|%n' {} + 2>/dev/null")
        return parse(out).filter { !$0.name.hasPrefix(".") }.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// All regular files under `dir`, recursively.
    static func listRecursive(_ serial: String, _ dir: String) throws -> [PhoneEntry] {
        let d = dir.hasSuffix("/") ? dir : dir + "/"
        let out = try AdbClient.exec(serial,
            "find \(d.shQuoted) -type f -exec stat -c '%f|%s|%Y|%n' {} + 2>/dev/null")
        return parse(out)
    }

    static func delete(_ serial: String, _ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try AdbClient.exec(serial, "rm -rf " + paths.map(\.shQuoted).joined(separator: " "))
    }

    static func makeFolder(_ serial: String, _ path: String) throws {
        try AdbClient.exec(serial, "mkdir -p \(path.shQuoted)")
    }

    static func freeSpace(_ serial: String) -> (free: Int64, total: Int64)? {
        guard let out = try? AdbClient.exec(serial, "df -k /sdcard 2>/dev/null | tail -1") else { return nil }
        let f = out.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 4, let total = Int64(f[1]), let avail = Int64(f[3]) else { return nil }
        return (avail * 1024, total * 1024)
    }

    /// Tells the media store about new files so they show up in Gallery / Files.
    static func mediaScan(_ serial: String, _ paths: [String]) {
        let media = paths.filter {
            ["jpg", "jpeg", "png", "heic", "webp", "gif", "mp4", "mov", "mkv", "webm", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
                .contains(($0 as NSString).pathExtension.lowercased())
        }
        guard !media.isEmpty else { return }
        for batch in stride(from: 0, to: media.count, by: 40).map({ Array(media[$0..<min($0 + 40, media.count)]) }) {
            let cmd = batch.map { "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(("file://" + $0).shQuoted) >/dev/null 2>&1" }
                .joined(separator: "; ")
            _ = try? AdbClient.exec(serial, cmd)
        }
    }

    private static func parse(_ out: String) -> [PhoneEntry] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let mode = UInt32(f[0], radix: 16) else { return nil }
            let path = String(f[3])
            return PhoneEntry(
                path: path,
                name: (path as NSString).lastPathComponent,
                isDirectory: mode & 0xF000 == 0x4000,
                size: Int64(f[1]) ?? 0,
                modified: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0)
            )
        }
    }
}
