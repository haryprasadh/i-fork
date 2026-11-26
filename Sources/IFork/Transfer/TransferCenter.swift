import Foundation
import Observation

@MainActor @Observable final class TransferJob: Identifiable {
    enum Direction { case toMac, toPhone }
    enum State: Equatable { case preparing, running, done, failed(String), cancelled }

    let id = UUID()
    let direction: Direction
    let title: String
    var state: State = .preparing
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var totalFiles = 0
    var doneFiles = 0
    var skippedFiles = 0
    var bytesPerSecond: Double = 0
    var laneRates: [Lane.Kind: Double] = [:]
    var revealURL: URL?
    var failures: [String] = []
    let startedAt = Date()
    var finishedAt: Date?

    // Written by worker threads, sampled by the ticker.
    @ObservationIgnored let cancelFlag = Locked(false)
    @ObservationIgnored let laneBytes = Locked<[Lane.Kind: Int64]>([:])
    @ObservationIgnored let filesDone = Locked(0)
    @ObservationIgnored var lastSample: (t: Date, bytes: Int64)?

    init(direction: Direction, title: String) {
        self.direction = direction
        self.title = title
    }

    var isActive: Bool { state == .preparing || state == .running }
    var progress: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    var averageSpeed: Double { elapsed > 0 ? Double(doneBytes) / elapsed : 0 }
    var eta: TimeInterval? {
        guard bytesPerSecond > 1, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / bytesPerSecond
    }
}

private struct WorkItem {
    let remote: String
    let local: URL
    let size: Int64
}

/// Hands out files to lanes. USB takes the biggest files; Wi-Fi takes the smallest,
/// and only when doing so finishes sooner than leaving it for USB.
private final class Scheduler: @unchecked Sendable {
    private var items: [WorkItem] // sorted big -> small
    private var remaining: Int64
    private let lock = NSLock()
    let hasUSB: Bool

    init(_ items: [WorkItem], hasUSB: Bool) {
        self.items = items.sorted { $0.size > $1.size }
        self.remaining = items.reduce(0) { $0 + $1.size }
        self.hasUSB = hasUSB
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return items.isEmpty }

    func next(for lane: Lane.Kind, usbRate: Double, wifiRate: Double) -> WorkItem? {
        lock.lock(); defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        if lane == .usb || !hasUSB {
            let it = items.removeFirst(); remaining -= it.size; return it
        }
        let cand = items[items.count - 1]
        let usbBusy = Double(remaining - cand.size) / max(usbRate, 1)
        let wifiTime = Double(cand.size) / max(wifiRate, 1)
        guard usbBusy >= wifiTime else { return nil }
        items.removeLast(); remaining -= cand.size
        return cand
    }

    func putBack(_ it: WorkItem) {
        lock.lock(); items.append(it); items.sort { $0.size > $1.size }; remaining += it.size; lock.unlock()
    }
}

@MainActor @Observable final class TransferCenter {
    static let shared = TransferCenter()

    private(set) var jobs: [TransferJob] = []
    var current: TransferJob? { jobs.first { $0.isActive } ?? jobs.first }

    @ObservationIgnored private var ticker: Timer?

    // MARK: public API

    func download(_ entries: [PhoneEntry], from phone: Phone, to dir: URL) {
        guard !entries.isEmpty else { return }
        let title = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        let job = TransferJob(direction: .toMac, title: "\(title) → \(dir.lastPathComponent)")
        job.revealURL = entries.count == 1 ? dir.appendingPathComponent(entries[0].name) : dir
        let primary = phone.primary
        start(job, phone: phone, onDone: nil) {
            var items: [WorkItem] = []
            var skipped = 0
            for e in entries {
                let parent = (e.path as NSString).deletingLastPathComponent
                let files = e.isDirectory ? try PhoneFS.listRecursive(primary, e.path) : [e]
                for f in files {
                    let rel = String(f.path.dropFirst(parent.count + 1))
                    let local = dir.appendingPathComponent(rel)
                    // Resume-friendly: an identical-size file already there is skipped.
                    if let a = try? FileManager.default.attributesOfItem(atPath: local.path),
                       (a[.size] as? NSNumber)?.int64Value == f.size {
                        skipped += 1; continue
                    }
                    items.append(WorkItem(remote: f.path, local: local, size: f.size))
                }
            }
            return (items, skipped)
        }
    }

    func upload(_ urls: [URL], to phone: Phone, remoteDir: String, onDone: @escaping @MainActor () -> Void) {
        guard !urls.isEmpty else { return }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let job = TransferJob(direction: .toPhone, title: "\(title) → \((remoteDir as NSString).lastPathComponent)")
        let primary = phone.primary
        start(job, phone: phone, onDone: onDone) {
            var items: [WorkItem] = []
            let fm = FileManager.default
            for url in urls {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                let base = url.deletingLastPathComponent().standardizedFileURL.path
                let files: [URL]
                if isDir.boolValue {
                    let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
                    files = (en?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                } else {
                    files = [url]
                }
                for f in files {
                    let rel = String(f.standardizedFileURL.path.dropFirst(base.count + 1))
                    let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    items.append(WorkItem(remote: remoteDir + "/" + rel, local: f, size: size))
                }
            }
            let total = items.reduce(0) { $0 + $1.size }
            if let space = PhoneFS.freeSpace(primary), total > space.free - 64 << 20 {
                throw AdbError.fail("Not enough space on the phone: needs \(Fmt.bytes(total)), \(Fmt.bytes(space.free)) free")
            }
            return (items, 0)
        }
    }

    func cancel(_ job: TransferJob) { job.cancelFlag.set(true) }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    // MARK: engine

    private func start(_ job: TransferJob, phone: Phone, onDone: (@MainActor () -> Void)?,
                       plan: @escaping () throws -> ([WorkItem], Int)) {
        jobs.insert(job, at: 0)
        if jobs.count > 20 { jobs.removeLast() }
        startTicker()
        let lanes = phone.lanes.filter { $0.kind == .usb || DeviceMonitor.shared.useWifiLane }
        let direction = job.direction

        DispatchQueue.global(qos: .userInitiated).async {
            let items: [WorkItem]
            let skipped: Int
            do { (items, skipped) = try plan() } catch {
                let msg = error.localizedDescription
                onMain { job.state = .failed(msg); job.finishedAt = Date() }
                return
            }
            let total = items.reduce(0) { $0 + $1.size }
            onMain {
                job.totalBytes = total; job.totalFiles = items.count; job.skippedFiles = skipped
                job.state = .running
            }
            let sched = Scheduler(items, hasUSB: lanes.contains { $0.kind == .usb })
            let failures = Locked<[String]>([])
            let pushed = Locked<[String]>([])
            let group = DispatchGroup()
            let t0 = Date()

            func rate(_ k: Lane.Kind, _ fallback: Double) -> Double {
                let dt = Date().timeIntervalSince(t0)
                let b = job.laneBytes.get()[k] ?? 0
                return dt > 2 && b > 0 ? Double(b) / dt : fallback
            }

            for lane in lanes {
                let perLane = Int(ProcessInfo.processInfo.environment["IFORK_WORKERS"] ?? "") ?? 2
                for _ in 0..<perLane {
                    group.enter()
                    Thread.detachNewThread {
                        defer { group.leave() }
                        var sync: AdbSync? = try? AdbSync(serial: lane.serial)
                        guard sync != nil else { return }
                        while !job.cancelFlag.get() {
                            guard let it = sched.next(for: lane.kind, usbRate: rate(.usb, 40e6), wifiRate: rate(.wifi, 20e6)) else {
                                if sched.isEmpty { break }
                                Thread.sleep(forTimeInterval: 0.15) // Wi-Fi waits: USB will finish sooner
                                continue
                            }
                            var attempt = 0
                            while true {
                                var moved: Int64 = 0
                                let progress: (Int) -> Void = { n in
                                    moved += Int64(n)
                                    job.laneBytes.update { $0[lane.kind, default: 0] += Int64(n) }
                                }
                                do {
                                    if sync == nil { sync = try AdbSync(serial: lane.serial) }
                                    if direction == .toMac {
                                        try sync!.pull(it.remote, to: it.local, progress: progress, isCancelled: { job.cancelFlag.get() })
                                    } else {
                                        try sync!.push(it.local, to: it.remote, progress: progress, isCancelled: { job.cancelFlag.get() })
                                        pushed.update { $0.append(it.remote) }
                                    }
                                    job.filesDone.update { $0 += 1 }
                                    break
                                } catch {
                                    job.laneBytes.update { $0[lane.kind, default: 0] -= moved } // undo partial progress
                                    sync = nil
                                    if job.cancelFlag.get() { break }
                                    attempt += 1
                                    if attempt >= 2 {
                                        if lane.kind == .wifi && sched.hasUSB { sched.putBack(it); return } // let USB finish it
                                        failures.update { $0.append("\((it.remote as NSString).lastPathComponent): \(error.localizedDescription)") }
                                        break
                                    }
                                }
                            }
                        }
                        sync?.quit()
                    }
                }
            }

            group.wait()
            if direction == .toPhone { PhoneFS.mediaScan(phone.primary, pushed.get()) }
            let fails = failures.get()
            onMain {
                self.sample(job)
                job.finishedAt = Date()
                job.failures = fails
                if job.cancelFlag.get() { job.state = .cancelled }
                else if !fails.isEmpty { job.state = .failed("\(fails.count) file(s) failed") }
                else { job.state = .done }
                onDone?()
            }
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = TransferCenter.shared
                let active = s.jobs.filter { $0.isActive }
                active.forEach { s.sample($0) }
                if active.isEmpty { s.ticker?.invalidate(); s.ticker = nil }
            }
        }
    }

    private func sample(_ job: TransferJob) {
        let lanes = job.laneBytes.get()
        let bytes = lanes.values.reduce(0, +)
        let now = Date()
        if let last = job.lastSample {
            let dt = now.timeIntervalSince(last.t)
            if dt > 0 {
                let inst = Double(bytes - last.bytes) / dt
                job.bytesPerSecond = job.bytesPerSecond == 0 ? inst : job.bytesPerSecond * 0.7 + inst * 0.3
            }
        }
        job.lastSample = (now, bytes)
        job.doneBytes = bytes
        job.doneFiles = job.filesDone.get()
        let el = max(now.timeIntervalSince(job.startedAt), 0.001)
        job.laneRates = lanes.mapValues { Double($0) / el }
    }
}
