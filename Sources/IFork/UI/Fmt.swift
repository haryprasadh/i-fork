import Foundation

enum Fmt {
    private static let byteFmt: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return f
    }()

    static func bytes(_ b: Int64) -> String { byteFmt.string(fromByteCount: b) }

    /// Memory-style size: "5.2 GB" (binary units, like Activity Monitor).
    static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

    /// Short disk size for tight spaces: "494 GB", "39.9 GB", "850 MB" (decimal, like Finder).
    static func short(_ b: Int64) -> String {
        let gb = Double(b) / 1e9
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1e6)
    }

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
