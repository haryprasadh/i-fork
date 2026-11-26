import Foundation
import AppKit
import Observation

struct InFlight: Identifiable, Equatable {
    let id: Int          // worker slot
    let name: String
    let size: Int64
    var done: Int64
    let lane: Lane.Kind
    var fraction: Double { size > 0 ? min(1, Double(done) / Double(size)) : 0 }
}

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
    @ObservationIgnored let slots = Locked<[Int: InFlight]>([:]) // worker slot -> file it's copying

    /// Files being copied right now (sampled from `slots`).
    var inFlight: [InFlight] = []

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
    var active: [TransferJob] { jobs.filter { $0.isActive } }

    @ObservationIgnored private var ticker: Timer?

    // MARK: public API

    func download(_ entries: [PhoneEntry], from phone: Phone, to dir: URL) {
        guard !entries.isEmpty else { return }
        let title = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        download(entries.map { ($0, dir.appendingPathComponent($0.name)) }, from: phone,
                 title: "\(title) → \(dir.lastPathComponent)",
                 reveal: entries.count == 1 ? dir.appendingPathComponent(entries[0].name) : dir,
                 onFinish: nil)
    }

    /// Core download: each phone entry (file or folder) goes to an exact local URL.
    func download(_ targets: [(PhoneEntry, URL)], from phone: Phone, title: String, reveal: URL?,
                  onFinish: (@MainActor (TransferJob) -> Void)?) {
        guard !targets.isEmpty else { return }
        let job = TransferJob(direction: .toMac, title: title)
        job.revealURL = reveal
        let primary = phone.primary
        start(job, phone: phone, onDone: { onFinish?(job) }) {
            var items: [WorkItem] = []
            var skipped = 0
            for (e, dest) in targets {
                let files = e.isDirectory ? try PhoneFS.listRecursive(primary, e.path) : [e]
                if e.isDirectory { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) }
                for f in files {
                    let local = e.isDirectory
                        ? dest.appendingPathComponent(String(f.path.dropFirst(e.path.count).drop(while: { $0 == "/" })))
                        : dest
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

    // MARK: drag to Finder (file promises)

    private struct Promise { let entry: PhoneEntry; let dest: URL; let done: (Error?) -> Void }
    @ObservationIgnored private var pendingPromises: [Promise] = []

    /// Finder asks for each dragged item separately; batch the ones from one drop into a single job.
    func fulfillPromise(_ entry: PhoneEntry, to dest: URL, completion: @escaping (Error?) -> Void) {
        guard let phone = DeviceMonitor.shared.phone else { completion(AdbError.fail("Phone disconnected")); return }
        // Dropped on the Bin: don't copy anything; offer to delete it from the phone instead.
        if dest.path.contains("/.Trash/") {
            completion(CocoaError(.userCancelled))
            let ui = UIState.shared
            if !ui.confirmDelete.contains(entry) { ui.confirmDelete.append(entry) }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        pendingPromises.append(Promise(entry: entry, dest: dest, done: completion))
        guard pendingPromises.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                let batch = self.pendingPromises
                self.pendingPromises = []
                let dir = batch[0].dest.deletingLastPathComponent()
                let title = batch.count == 1 ? batch[0].entry.name : "\(batch.count) items"
                self.download(batch.map { ($0.entry, $0.dest) }, from: phone, title: "\(title) → \(dir.lastPathComponent)",
                              reveal: batch.count == 1 ? batch[0].dest : dir) { job in
                    let err: Error? = job.state == .done ? nil : AdbError.fail(job.failures.first ?? "Transfer failed")
                    batch.forEach { $0.done(err) }
                }
            }
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
                onMain { job.state = .failed(msg); job.finishedAt = Date(); job.failures = [msg]; onDone?() } // always report back
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

            for (li, lane) in lanes.enumerated() {
                let perLane = Int(ProcessInfo.processInfo.environment["IFORK_WORKERS"] ?? "") ?? 2
                for k in 0..<perLane {
                    let slot = li * 10 + k
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
                            job.slots.update { $0[slot] = InFlight(id: slot, name: (it.remote as NSString).lastPathComponent,
                                                                   size: it.size, done: 0, lane: lane.kind) }
                            defer { job.slots.update { _ = $0.removeValue(forKey: slot) } }
                            while true {
                                var moved: Int64 = 0
                                let progress: (Int) -> Void = { n in
                                    moved += Int64(n)
                                    job.laneBytes.update { $0[lane.kind, default: 0] += Int64(n) }
                                    job.slots.update { $0[slot]?.done = moved }
                                }
                                do {
                                    if sync == nil { sync = try AdbSync(serial: lane.serial) }
                                    if direction == .toMac {
                                        let finder = FinderProgress(file: it.local.appendingPathExtension("ifpart"), size: it.size)
                                        defer { finder.finish() }
                                        let part = it.local.appendingPathExtension("ifpart")
                                        var lastCheck = Date()
                                        try sync!.pull(it.remote, to: it.local, progress: { n in progress(n); finder.add(n) },
                                                       isCancelled: {
                                            if job.cancelFlag.get() { return true }
                                            // Destination moved or trashed mid-copy (e.g. folder dragged to the Bin): stop the job.
                                            if Date().timeIntervalSince(lastCheck) > 1 {
                                                lastCheck = Date()
                                                if !FileManager.default.fileExists(atPath: part.path) { job.cancelFlag.set(true); return true }
                                            }
                                            return false
                                        })
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
        let live = job.slots.get().values.sorted { $0.id < $1.id }
        if live != job.inFlight { job.inFlight = live }
        let el = max(now.timeIntervalSince(job.startedAt), 0.001)
        job.laneRates = lanes.mapValues { Double($0) / el }
    }
}

/// Publishes an NSProgress for a file so Finder draws a progress pie on it (like Safari downloads).
private final class FinderProgress {
    private let progress: Progress?
    private var pending: Int64 = 0

    init(file: URL, size: Int64) {
        guard size > 8 << 20 else { progress = nil; return } // only worth it for bigger files
        let p = Progress(totalUnitCount: size)
        p.kind = .file
        p.fileOperationKind = .downloading
        p.fileURL = file
        p.isCancellable = false
        p.publish()
        progress = p
    }

    func add(_ n: Int) {
        guard let progress else { return }
        pending += Int64(n)
        if pending >= 1 << 20 { progress.completedUnitCount += pending; pending = 0 }
    }

    func finish() { progress?.unpublish() }
}
