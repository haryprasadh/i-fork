import Foundation
import Observation
import Darwin

struct Usage: Equatable {
    let used: Int64
    let total: Int64
    var free: Int64 { max(0, total - used) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Storage + memory for the phone and this Mac, refreshed every few seconds.
@MainActor @Observable final class Stats {
    static let shared = Stats()

    private(set) var phoneStorage: Usage?
    private(set) var phoneRAM: Usage?
    private(set) var macStorage: Usage?
    private(set) var macRAM: Usage?
    private(set) var macVolume = ""
    let macName = Host.current().localizedName ?? "This Mac"

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { Stats.shared.refresh() }
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let serial = DeviceMonitor.shared.phone?.primary
        let saveDir = UIState.shared.saveDir
        DispatchQueue.global(qos: .utility).async {
            let phone = serial.flatMap(Stats.phoneStats)
            let disk = Stats.macDisk(saveDir)
            let ram = Stats.macMemory()
            onMain {
                self.busy = false
                self.phoneStorage = phone?.storage ?? (serial == nil ? nil : self.phoneStorage)
                self.phoneRAM = phone?.ram ?? (serial == nil ? nil : self.phoneRAM)
                self.macStorage = disk?.usage
                self.macVolume = disk?.name ?? ""
                self.macRAM = ram
            }
        }
    }

    // MARK: phone (one shell round trip)

    nonisolated private static func phoneStats(_ serial: String) -> (storage: Usage?, ram: Usage?)? {
        guard let out = try? AdbClient.exec(serial,
            "df -k /sdcard 2>/dev/null | tail -1; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo") else { return nil }
        var storage: Usage?, memTotal: Int64?, memAvail: Int64?
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if line.hasPrefix("MemTotal:"), f.count >= 2 { memTotal = Int64(f[1]) }
            else if line.hasPrefix("MemAvailable:"), f.count >= 2 { memAvail = Int64(f[1]) }
            else if f.count >= 4, let total = Int64(f[1]), let avail = Int64(f[3]) {
                storage = Usage(used: (total - avail) * 1024, total: total * 1024)
            }
        }
        let ram = memTotal.flatMap { t in memAvail.map { Usage(used: (t - $0) * 1024, total: t * 1024) } }
        return (storage, ram)
    }

    // MARK: Mac

    /// The volume the save folder lives on, using Finder's "available" (includes purgeable space).
    nonisolated private static func macDisk(_ dir: URL) -> (usage: Usage, name: String)? {
        var url = dir
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Usage(used: Int64(total) - avail, total: Int64(total)), v.volumeLocalizedName ?? "")
    }

    /// "Memory Used" the way Activity Monitor counts it: app memory + wired + compressed.
    nonisolated private static func macMemory() -> Usage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Int64(sysconf(_SC_PAGESIZE))
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        return Usage(used: used, total: Int64(ProcessInfo.processInfo.physicalMemory))
    }
}
