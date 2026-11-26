import Foundation

struct AdbTransport: Hashable {
    let serial: String          // "00045345N000033" or "192.168.1.8:34425"
    let state: String           // device, unauthorized, offline, ...
    let props: [String: String] // model:, product:, usb:, transport_id:

    var isWifi: Bool { serial.contains(":") || serial.contains("._adb-tls-connect") }
}

/// Stateless helpers around the adb server's host protocol.
enum AdbClient {
    static let adbPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/Applications/MacDroid.app/Contents/Resources/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Makes sure an adb server is listening on 5037 (starts one if needed).
    static func ensureServer() throws {
        if (try? AdbSocket()) != nil { return }
        guard let adb = adbPath else {
            throw AdbError.connect("adb not found. Install it with: brew install android-platform-tools")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["start-server"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        _ = try AdbSocket()
    }

    static func parseDevices(_ text: String) -> [AdbTransport] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return nil }
            var props: [String: String] = [:]
            for p in parts.dropFirst(2) {
                let kv = p.split(separator: ":", maxSplits: 1)
                if kv.count == 2 { props[String(kv[0])] = String(kv[1]) }
            }
            return AdbTransport(serial: String(parts[0]), state: String(parts[1]), props: props)
        }
    }

    static func devices() throws -> [AdbTransport] {
        let s = try AdbSocket()
        try s.request("host:devices-l")
        return parseDevices(try s.readHexString())
    }

    /// Blocks forever, calling `onUpdate` whenever the device list changes. Throws when the server goes away.
    static func trackDevices(_ onUpdate: ([AdbTransport]) -> Void) throws {
        let s = try AdbSocket()
        try s.request("host:track-devices-l")
        while true { onUpdate(parseDevices(try s.readHexString())) }
    }

    static func connect(_ hostPort: String) throws -> String {
        let s = try AdbSocket()
        try s.request("host:connect:\(hostPort)")
        return try s.readHexString()
    }

    static func disconnect(_ hostPort: String) {
        guard let s = try? AdbSocket() else { return }
        try? s.request("host:disconnect:\(hostPort)")
    }

    /// Opens a socket already switched to the given device transport.
    static func open(_ serial: String) throws -> AdbSocket {
        let s = try AdbSocket()
        try s.request("host:transport:\(serial)")
        return s
    }

    /// Runs a shell command on the device (no PTY, raw stdout) and returns its output.
    @discardableResult
    static func exec(_ serial: String, _ command: String) throws -> String {
        let s = try open(serial)
        try s.request("exec:\(command)")
        return String(decoding: try s.readAll(), as: UTF8.self)
    }
}

extension String {
    /// Single-quotes a string for /system/bin/sh.
    var shQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
