import Foundation

/// Headless benchmark: `iFork --bench pull <remotePath> <localDir> [--usb-only]`
///                   `iFork --bench push <localPath> <remoteDir> [--usb-only]`
@MainActor enum Bench {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--bench"), args.count >= i + 4 else { return }
        let mode = args[i + 1], a = args[i + 2], b = args[i + 3]
        let devices = DeviceMonitor.shared
        devices.useWifiLane = !args.contains("--usb-only")
        devices.start()
        spin(until: { devices.phone != nil && (!devices.useWifiLane || devices.phone?.wifi != nil) }, timeout: 15)
        guard let phone = devices.phone else { print("no phone"); exit(1) }
        print("phone: \(phone.name)  lanes: \(phone.lanes.map(\.kind.rawValue).joined(separator: "+"))")

        let center = TransferCenter.shared
        if mode == "pull" {
            let parent = (a as NSString).deletingLastPathComponent
            let entry = (try? PhoneFS.list(phone.primary, parent))?.first { $0.path == a }
            guard let entry else { print("not found: \(a)"); exit(1) }
            center.download([entry], from: phone, to: URL(fileURLWithPath: b))
        } else {
            center.upload([URL(fileURLWithPath: a)], to: phone, remoteDir: b) {}
        }
        guard let job = center.current else { exit(1) }
        var last = Date()
        spin(until: {
            if Date().timeIntervalSince(last) >= 1 {
                last = Date()
                print(String(format: "  %5.1f%%  %@  [%@]", job.progress * 100, Fmt.speed(job.bytesPerSecond),
                             job.laneRates.map { "\($0.key.rawValue) \(Fmt.speed($0.value))" }.sorted().joined(separator: ", ")))
            }
            return !job.isActive
        }, timeout: 3600)
        print("result: \(job.state)  \(job.doneFiles)/\(job.totalFiles) files  \(Fmt.bytes(job.doneBytes)) in \(String(format: "%.1f", job.elapsed))s  avg \(Fmt.speed(job.averageSpeed))")
        let lanes = job.laneBytes.get()
        for (k, v) in lanes.sorted(by: { $0.key.rawValue > $1.key.rawValue }) { print("  \(k.rawValue): \(Fmt.bytes(v))") }
        if !job.failures.isEmpty { print("failures: \(job.failures.prefix(5))") }
        exit(job.state == .done ? 0 : 2)
    }

    private static func spin(until done: () -> Bool, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
