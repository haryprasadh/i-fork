import Foundation
import Observation

struct Phone: Identifiable, Equatable {
    let id: String          // ro.serialno (same for USB and Wi-Fi transports)
    var name: String
    var usb: String?        // transport serial
    var wifi: String?
    var primary: String { usb ?? wifi ?? "" }
    var lanes: [Lane] {
        var l: [Lane] = []
        if let usb { l.append(Lane(kind: .usb, serial: usb)) }
        if let wifi { l.append(Lane(kind: .wifi, serial: wifi)) }
        return l
    }
}

struct Lane: Hashable {
    enum Kind: String { case usb = "USB", wifi = "Wi-Fi" }
    let kind: Kind
    let serial: String
}

/// Watches adb for phones, groups USB + Wi-Fi transports of the same phone,
/// and auto-connects the Wi-Fi lane when Wireless debugging is on.
@MainActor @Observable final class DeviceMonitor {
    static let shared = DeviceMonitor()

    private(set) var phones: [Phone] = []
    private(set) var needsAuthorization = false
    private(set) var serverError: String?
    private(set) var wifiHint: String?
    var useWifiLane: Bool = UserDefaults.standard.object(forKey: "useWifiLane") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useWifiLane, forKey: "useWifiLane"); if useWifiLane { kickWifi() } }
    }

    var phone: Phone? { phones.first }

    /// Phones the user ejected: still plugged in, but iFork leaves them alone until Reconnect or replug.
    private(set) var ejected: [Phone] = []
    private(set) var connectingWifi = false
    @ObservationIgnored private var ejectedIds = Set<String>()
    @ObservationIgnored private var resolvedCache: [(AdbTransport, String, String)] = []

    @ObservationIgnored private var info: [String: (id: String, name: String)] = [:] // transport serial -> phone
    @ObservationIgnored private var probing = Set<String>()
    @ObservationIgnored private var lastTransports: [AdbTransport] = []
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        Thread.detachNewThread { [weak self] in
            while true {
                do {
                    try AdbClient.ensureServer()
                    onMain { self?.serverError = nil }
                    try AdbClient.trackDevices { list in self?.handle(list) }
                } catch {
                    let msg = error.localizedDescription
                    onMain { self?.serverError = msg }
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// Called on the tracking thread.
    nonisolated private func handle(_ list: [AdbTransport]) {
        var resolved: [(AdbTransport, String, String)] = []
        for t in list where t.state == "device" {
            let known = onMainSync { self.info[t.serial] }
            if let k = known { resolved.append((t, k.id, k.name)); continue }
            guard let out = try? AdbClient.exec(t.serial,
                "getprop ro.serialno; echo $(getprop ro.product.marketname)$(getprop ro.product.brand_device_name); getprop ro.product.manufacturer; getprop ro.product.model") else { continue }
            let l = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let id = l.first.flatMap { $0.isEmpty ? nil : $0 } ?? t.serial
            let market = l.count > 1 ? l[1] : ""
            let maker = l.count > 2 ? l[2] : ""
            let model = l.count > 3 ? l[3] : (t.props["model"] ?? "Android")
            let name = !market.isEmpty ? market : [maker, model].filter { !$0.isEmpty }.joined(separator: " ")
            onMainSync { self.info[t.serial] = (id, name) }
            resolved.append((t, id, name))
        }
        let unauthorized = list.contains { $0.state == "unauthorized" }
        onMain {
            self.lastTransports = list
            self.resolvedCache = resolved
            self.publish()
            self.needsAuthorization = unauthorized && self.phones.isEmpty && self.ejected.isEmpty
        }
    }

    private func publish() {
        var byId: [String: Phone] = [:]
        var order: [String] = []
        for (t, id, name) in resolvedCache {
            if byId[id] == nil { byId[id] = Phone(id: id, name: name); order.append(id) }
            if t.isWifi { byId[id]?.wifi = t.serial } else { byId[id]?.usb = t.serial }
        }
        let all = order.compactMap { byId[$0] }
        ejectedIds = ejectedIds.intersection(all.map(\.id)) // unplugged = forget the eject
        phones = all.filter { !ejectedIds.contains($0.id) }
        ejected = all.filter { ejectedIds.contains($0.id) }
        kickWifi()
    }

    // MARK: user actions

    /// Stops transfers, drops the Wi-Fi lane and hides the phone so it's safe to unplug.
    func eject(_ phone: Phone) {
        TransferCenter.shared.active.forEach { TransferCenter.shared.cancel($0) }
        ejectedIds.insert(phone.id)
        if let wifi = phone.wifi { DispatchQueue.global().async { AdbClient.disconnect(wifi) } }
        wifiHint = nil
        publish()
    }

    func reconnect(_ phone: Phone) {
        ejectedIds.remove(phone.id)
        probing.remove(phone.id)
        publish()
    }

    /// Try the Wi-Fi lane again right now (e.g. after turning on Wireless debugging).
    func retryWifi() {
        probing.removeAll()
        wifiHint = nil
        if !useWifiLane { useWifiLane = true } else { kickWifi() }
    }

    /// Wi-Fi only, no cable: pair with the code from "Pair device with pairing code", then connect.
    func connectWireless(pairAddress: String, code: String, connectAddress: String, done: @escaping @MainActor (String?) -> Void) {
        connectingWifi = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                if !code.isEmpty && !pairAddress.isEmpty {
                    let s = try AdbSocket()
                    try s.request("host:pair:\(code):\(pairAddress)")
                    let msg = (try? s.readHexString()) ?? ""
                    if msg.lowercased().contains("fail") || msg.lowercased().contains("error") { throw AdbError.fail(msg) }
                }
                let msg = try AdbClient.connect(connectAddress)
                if !msg.contains("connected") { throw AdbError.fail(msg) }
            } catch { failure = error.localizedDescription }
            onMain { self.connectingWifi = false; done(failure) }
        }
    }

    private func kickWifi() {
        guard useWifiLane else { return }
        for p in phones where p.usb != nil && p.wifi == nil && !probing.contains(p.id) {
            probing.insert(p.id)
            connectingWifi = true
            let usb = p.usb!, id = p.id
            DispatchQueue.global(qos: .utility).async {
                let hint = DeviceMonitor.connectWifiLane(usb: usb, phoneId: id)
                onMain {
                    self.connectingWifi = false
                    self.wifiHint = hint
                    // Retry later if it failed (e.g. Wi-Fi toggled on afterwards).
                    DispatchQueue.main.asyncAfter(deadline: .now() + (hint == nil ? 2 : 20)) { MainActor.assumeIsolated { _ = self.probing.remove(id) } }
                }
            }
        }
    }

    /// Finds the phone's Wireless-debugging port via the USB lane and connects to it.
    /// Returns nil on success, or a user-facing hint.
    nonisolated private static func connectWifiLane(usb: String, phoneId: String) -> String? {
        guard let out = try? AdbClient.exec(usb,
            "settings get global adb_wifi_enabled; ip -4 -o addr show wlan0 2>/dev/null; ss -ltn 2>/dev/null") else { return nil }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "1" else {
            return "Turn on Wireless debugging (Developer options) to add a Wi-Fi lane"
        }
        guard let inet = lines.first(where: { $0.contains(" inet ") }),
              let r = inet.range(of: #"inet (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else {
            return "Connect the phone to Wi-Fi to add a Wi-Fi lane"
        }
        let ip = String(inet[r].dropFirst(5))
        var ports: [Int] = lines.compactMap { line in
            guard line.hasPrefix("LISTEN") else { return nil }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4 else { return nil }
            let local = String(cols[3])
            guard local.hasPrefix("*:") || local.hasPrefix("0.0.0.0:") || local.hasPrefix("[::]:") else { return nil }
            guard let port = Int(local.split(separator: ":").last ?? ""), port >= 1024 else { return nil }
            return port
        }
        let key = "wifiPort.\(phoneId)"
        let remembered = UserDefaults.standard.integer(forKey: key)
        if remembered > 0, let i = ports.firstIndex(of: remembered) { ports.remove(at: i); ports.insert(remembered, at: 0) }

        for port in ports {
            let target = "\(ip):\(port)"
            guard let msg = try? AdbClient.connect(target), msg.contains("connected") else {
                AdbClient.disconnect(target); continue
            }
            // Wait for the transport to come online and confirm it's the same phone.
            for _ in 0..<15 {
                if let t = (try? AdbClient.devices())?.first(where: { $0.serial == target }), t.state == "device" {
                    let sn = (try? AdbClient.exec(target, "getprop ro.serialno"))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sn == phoneId {
                        UserDefaults.standard.set(port, forKey: key)
                        return nil
                    }
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            AdbClient.disconnect(target)
        }
        return "Couldn't open a Wi-Fi lane. Open Wireless debugging once on the phone, then retry"
    }
}
