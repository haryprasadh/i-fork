import Foundation
import Network
import Observation
import Darwin

@MainActor @Observable final class WifiDropServer {
    static let shared = WifiDropServer()

    private(set) var isRunning = false
    private(set) var url: URL?
    private(set) var bytesPerSecond: Double = 0
    private(set) var activeTransfers = 0
    private(set) var received: [URL] = []
    private(set) var shared: [URL] = []
    var saveDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/iFork", isDirectory: true)

    private var server: HTTPServer?
    private var timer: Timer?
    private var previousBytes: UInt64 = 0
    private let meter = WifiByteMeter()
    private var token = ""
    private var offered: [String: URL] = [:]
    private var idsByPath: [String: String] = [:]

    private init() {}

    func start() throws {
        guard server == nil else { return }
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let server = try HTTPServer(token: token, meter: meter,
            saveDirectory: { [weak self] in self?.saveDirectory },
            files: { [weak self] in self?.fileSnapshot() ?? [] },
            didReceive: { [weak self] file in
                guard let self else { return }
                self.received.insert(file, at: 0)
            },
            transferDelta: { [weak self] delta in
                guard let self else { return }
                self.activeTransfers = max(0, self.activeTransfers + delta)
            },
            didListen: { [weak self] port in
                guard let self, self.server != nil else { return }
                self.url = URL(string: "http://\(Self.lanAddress()):\(port)/?k=\(self.token)")
                self.isRunning = true
            },
            didFail: { [weak self] in self?.stop() })
        self.server = server
        server.start()
        previousBytes = meter.total
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSpeed() }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        timer?.invalidate()
        timer = nil
        url = nil
        isRunning = false
        activeTransfers = 0
        bytesPerSecond = 0
        token = ""
    }

    func share(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL { addFile(file) }
            } else {
                addFile(url)
            }
        }
    }

    func unshare(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let id = idsByPath.removeValue(forKey: path) { offered.removeValue(forKey: id) }
        shared.removeAll { $0.standardizedFileURL.path == path }
    }

    private func addFile(_ url: URL) {
        let file = url.standardizedFileURL
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              idsByPath[file.path] == nil else { return }
        let id = UUID().uuidString
        idsByPath[file.path] = id
        offered[id] = file
        shared.append(file)
    }

    private func fileSnapshot() -> [HTTPSharedFile] {
        offered.compactMap { id, url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return HTTPSharedFile(id: id, url: url, size: UInt64(size))
        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    private func updateSpeed() {
        let now = meter.total
        let sample = Double(now &- previousBytes) * 4
        previousBytes = now
        bytesPerSecond = bytesPerSecond * 0.65 + sample * 0.35
        if sample == 0 && bytesPerSecond < 1024 { bytesPerSecond = 0 }
    }

    private static func lanAddress() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        var candidates: [(Int, String)] = []
        var cursor = interfaces
        while let item = cursor?.pointee {
            defer { cursor = item.ifa_next }
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (item.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: item.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }
            candidates.append((name == "en0" ? 0 : name == "en1" ? 1 : 2, ip))
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1 ?? "127.0.0.1"
    }
}

final class WifiByteMeter {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var total: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func add(_ bytes: Int) { lock.lock(); value &+= UInt64(bytes); lock.unlock() }
}
