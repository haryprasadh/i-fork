import Foundation

enum Fmt {
    private static let byteFmt: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return f
    }()

    static func bytes(_ b: Int64) -> String { byteFmt.string(fromByteCount: b) }

    static func speed(_ bps: Double) -> String {
        bps >= 1e6 ? String(format: "%.1f MB/s", bps / 1e6) : String(format: "%.0f KB/s", bps / 1e3)
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}
