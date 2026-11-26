import Foundation
import Network
import Darwin

struct HTTPSharedFile {
    let id: String
    let url: URL
    let size: UInt64
}

final class HTTPServer: @unchecked Sendable {
    private var listener: NWListener
    private var triedFallback = false
    private var stopped = false
    private let queue = DispatchQueue(label: "ifork.wifi.listener")
    private var clients: [UUID: HTTPClient] = [:]
    let token: String
    let meter: WifiByteMeter
    let saveDirectory: @MainActor () -> URL?
    let files: @MainActor () -> [HTTPSharedFile]
    let didReceive: @MainActor (URL) -> Void
    let transferDelta: @MainActor (Int) -> Void
    let didListen: @MainActor (UInt16) -> Void
    let didFail: @MainActor () -> Void

    init(token: String, meter: WifiByteMeter, saveDirectory: @escaping @MainActor () -> URL?,
         files: @escaping @MainActor () -> [HTTPSharedFile],
         didReceive: @escaping @MainActor (URL) -> Void,
         transferDelta: @escaping @MainActor (Int) -> Void,
         didListen: @escaping @MainActor (UInt16) -> Void,
         didFail: @escaping @MainActor () -> Void) throws {
        self.token = token
        self.meter = meter
        self.saveDirectory = saveDirectory
        self.files = files
        self.didReceive = didReceive
        self.transferDelta = transferDelta
        self.didListen = didListen
        self.didFail = didFail
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 53317)!)
        } catch {
            listener = try NWListener(using: parameters, on: .any)
        }
    }

    func start() {
        configureListener()
    }

    private func configureListener() {
        let activeListener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard self.listener === activeListener else { return }
            switch state {
            case .ready:
                let port = self.listener.port?.rawValue ?? 53317
                Task { @MainActor in self.didListen(port) }
            case .failed:
                guard !self.stopped else { return }
                if !self.triedFallback {
                    self.triedFallback = true
                    self.listener.cancel()
                    do {
                        self.listener = try NWListener(using: .tcp, on: .any)
                        self.configureListener()
                    } catch { Task { @MainActor in self.didFail() } }
                } else { Task { @MainActor in self.didFail() } }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            let client = HTTPClient(connection: connection, server: self) { [weak self] in
                self?.queue.async { self?.clients.removeValue(forKey: id) }
            }
            self.clients[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            listener.cancel()
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
        }
    }
}

private final class HTTPClient: @unchecked Sendable {
    private enum State { case headers, upload(Upload), responding }
    private final class Upload {
        let handle: FileHandle
        let url: URL
        var remaining: UInt64
        init(handle: FileHandle, url: URL, remaining: UInt64) {
            self.handle = handle; self.url = url; self.remaining = remaining
        }
    }

    private let connection: NWConnection
    private let server: HTTPServer
    private let queue = DispatchQueue(label: "ifork.wifi.client")
    private let onClose: () -> Void
    private var buffer = Data()
    private var state: State = .headers
    private var closed = false
    private var transferActive = false
    private static let nameLock = NSLock()
    private static let blockSize = 1_048_576

    init(connection: NWConnection, server: HTTPServer, onClose: @escaping () -> Void) {
        self.connection = connection; self.server = server; self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() { queue.async { self.close() } }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.blockSize) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            self.process()
            if done || error != nil { self.close(); return }
            if case .responding = self.state { return }
            self.receive()
        }
    }

    private func process() {
        while !closed {
            switch state {
            case .headers:
                guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 65_536 { respond(431, "Headers too large") }
                    return
                }
                let head = Data(buffer[..<boundary.lowerBound])
                buffer.removeSubrange(..<boundary.upperBound)
                guard let text = String(data: head, encoding: .utf8) else { respond(400, "Bad request"); return }
                handleHeaders(text)
                if case .responding = state { return }
            case .upload(let upload):
                let count = min(buffer.count, Int(min(upload.remaining, UInt64(Self.blockSize))))
                if count > 0 {
                    do {
                        try upload.handle.write(contentsOf: buffer.prefix(count))
                        buffer.removeSubrange(..<count)
                        upload.remaining -= UInt64(count)
                        server.meter.add(count)
                    } catch {
                        try? upload.handle.close()
                        try? FileManager.default.removeItem(at: upload.url)
                        endTransfer()
                        respond(500, "Disk write failed")
                        return
                    }
                }
                if upload.remaining == 0 {
                    try? upload.handle.close()
                    endTransfer()
                    Task { @MainActor in server.didReceive(upload.url) }
                    respond(201, "Saved")
                    return
                }
                return
            case .responding: return
            }
        }
    }

    private func handleHeaders(_ text: String) {
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { respond(400, "Bad request"); return }
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
              let url = URLComponents(string: "http://localhost\(parts[1])") else {
            respond(400, "Bad request"); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard query["k"] == server.token || headers["x-token"] == server.token else {
            respond(403, "Forbidden"); return
        }
        let method = String(parts[0])
        switch (method, url.path) {
        case ("GET", "/"):
            respond(200, WifiWebPage.html, type: "text/html; charset=utf-8")
        case ("GET", "/files"):
            Task { @MainActor in
                let files = server.files().map { ["id": $0.id, "name": $0.url.lastPathComponent, "size": $0.size] as [String: Any] }
                let data = (try? JSONSerialization.data(withJSONObject: files)) ?? Data("[]".utf8)
                queue.async { self.respond(200, data: data, type: "application/json") }
            }
        case ("PUT", "/upload"):
            guard let lengthText = headers["content-length"], let length = UInt64(lengthText),
                  let sizeText = query["size"], let size = UInt64(sizeText), size == length,
                  let name = query["name"], !name.isEmpty else {
                respond(400, "Missing name or size"); return
            }
            if headers["expect"]?.lowercased() == "100-continue" {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                })
            }
            Task { @MainActor in
                let directory = server.saveDirectory()
                queue.async { self.beginUpload(directory: directory, name: name, length: length) }
            }
        case ("GET", let path) where path.hasPrefix("/download/"):
            let id = String(path.dropFirst("/download/".count))
            Task { @MainActor in
                let file = server.files().first { $0.id == id }
                queue.async { self.beginDownload(file: file, range: headers["range"]) }
            }
        default:
            respond(404, "Not found")
        }
        state = .responding
    }

    private func beginUpload(directory: URL?, name: String, length: UInt64) {
        guard !closed, let directory else { respond(500, "Save folder unavailable"); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (url, handle) = try Self.createFile(directory: directory, name: name)
            state = .upload(Upload(handle: handle, url: url, remaining: length))
            beginTransfer()
            process()
            if case .upload = state { receive() }
        } catch { respond(500, "Cannot create file") }
    }

    private static func createFile(directory: URL, name: String) throws -> (URL, FileHandle) {
        let clean = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = clean.isEmpty || clean == "." ? "upload" : clean
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        nameLock.lock(); defer { nameLock.unlock() }
        for number in 0..<Int.max {
            let candidate = number == 0 ? safe : "\(base) (\(number))\(ext.isEmpty ? "" : ".\(ext)")"
            let url = directory.appendingPathComponent(candidate)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            if fd >= 0 { return (url, FileHandle(fileDescriptor: fd, closeOnDealloc: true)) }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw POSIXError(.EEXIST)
    }

    private func beginDownload(file: HTTPSharedFile?, range: String?) {
        guard !closed else { return }
        guard let file else { respond(404, "File unavailable"); return }
        let total = file.size
        var start: UInt64 = 0
        var end = total > 0 ? total - 1 : 0
        var partial = false
        if let range {
            guard range.hasPrefix("bytes="), !range.dropFirst(6).contains(",") else {
                rangeNotSatisfiable(total); return
            }
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, total > 0 else { rangeNotSatisfiable(total); return }
            if bounds[0].isEmpty {
                guard let suffix = UInt64(bounds[1]), suffix > 0 else { rangeNotSatisfiable(total); return }
                start = total > suffix ? total - suffix : 0
            } else {
                guard let parsed = UInt64(bounds[0]), parsed < total else { rangeNotSatisfiable(total); return }
                start = parsed
                if !bounds[1].isEmpty {
                    guard let parsedEnd = UInt64(bounds[1]), parsedEnd >= start else { rangeNotSatisfiable(total); return }
                    end = min(parsedEnd, total - 1)
                }
            }
            partial = true
        }
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            try handle.seek(toOffset: start)
            let length = total == 0 ? 0 : end - start + 1
            let filename = file.url.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            var extra = "Accept-Ranges: bytes\r\nContent-Disposition: attachment; filename=\"\(filename)\"\r\n"
            if partial { extra += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
            state = .responding
            beginTransfer()
            sendHeader(status: partial ? 206 : 200, length: length, type: "application/octet-stream", extra: extra) { [weak self] in
                self?.sendFile(handle, remaining: length)
            }
        } catch { respond(404, "File unavailable") }
    }

    private func rangeNotSatisfiable(_ total: UInt64) {
        respond(416, "Range not satisfiable", extra: "Content-Range: bytes */\(total)\r\n")
    }

    private func sendFile(_ handle: FileHandle, remaining: UInt64) {
        guard !closed else { try? handle.close(); return }
        guard remaining > 0 else { try? handle.close(); endTransfer(); completeResponse(); return }
        do {
            guard let data = try handle.read(upToCount: Int(min(remaining, UInt64(Self.blockSize)))), !data.isEmpty else {
                try? handle.close(); endTransfer(); close(); return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { try? handle.close(); self.endTransfer(); self.close(); return }
                self.server.meter.add(data.count)
                self.sendFile(handle, remaining: remaining - UInt64(data.count))
            })
        } catch { try? handle.close(); endTransfer(); close() }
    }

    private func respond(_ status: Int, _ text: String, type: String = "text/plain; charset=utf-8", extra: String = "") {
        respond(status, data: Data(text.utf8), type: type, extra: extra)
    }

    private func respond(_ status: Int, data: Data, type: String, extra: String = "") {
        guard !closed else { return }
        state = .responding
        sendHeader(status: status, length: UInt64(data.count), type: type, extra: extra) { [weak self] in
            guard let self else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error == nil { self?.completeResponse() } else { self?.close() }
            })
        }
    }

    private func sendHeader(status: Int, length: UInt64, type: String, extra: String, then: @escaping () -> Void) {
        let reason = [200: "OK", 201: "Created", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden",
                      404: "Not Found", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 500: "Internal Server Error"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(length)\r\nContent-Type: \(type)\r\nConnection: keep-alive\r\nCache-Control: no-store\r\n\(extra)\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error == nil { then() } else { self?.close() }
        })
    }

    private func completeResponse() {
        guard !closed else { return }
        state = .headers
        if !buffer.isEmpty { process() }
        if case .responding = state { return }
        receive()
    }

    private func beginTransfer() {
        transferActive = true
        Task { @MainActor in server.transferDelta(1) }
    }

    private func endTransfer() {
        guard transferActive else { return }
        transferActive = false
        Task { @MainActor in server.transferDelta(-1) }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        if case .upload(let upload) = state {
            try? upload.handle.close()
            try? FileManager.default.removeItem(at: upload.url)
        }
        endTransfer()
        connection.cancel()
        onClose()
    }
}
