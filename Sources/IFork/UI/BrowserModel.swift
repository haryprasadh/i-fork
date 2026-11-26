import Foundation
import Observation
import CoreTransferable
import UniformTypeIdentifiers

struct Place: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let icon: String
    let path: String

    static let all: [Place] = [
        Place(name: "Phone", icon: "iphone", path: "/sdcard"),
        Place(name: "Camera", icon: "camera", path: "/sdcard/DCIM/Camera"),
        Place(name: "Screenshots", icon: "camera.viewfinder", path: "/sdcard/Pictures/Screenshots"),
        Place(name: "Screenshots", icon: "camera.viewfinder", path: "/sdcard/DCIM/Screenshots"),
        Place(name: "Downloads", icon: "arrow.down.circle", path: "/sdcard/Download"),
        Place(name: "Documents", icon: "doc", path: "/sdcard/Documents"),
        Place(name: "Pictures", icon: "photo", path: "/sdcard/Pictures"),
        Place(name: "Movies", icon: "film", path: "/sdcard/Movies"),
        Place(name: "Music", icon: "music.note", path: "/sdcard/Music"),
        Place(name: "Recordings", icon: "waveform", path: "/sdcard/Recordings"),
        Place(name: "WhatsApp", icon: "message", path: "/sdcard/Android/media/com.whatsapp/WhatsApp/Media"),
    ]
}

@MainActor @Observable final class BrowserModel {
    static let shared = BrowserModel()
    private(set) var path = PhoneFS.root
    private(set) var entries: [PhoneEntry] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var places: [Place] = [Place.all[0]]
    private(set) var freeSpace: (free: Int64, total: Int64)?
    var selection = Set<PhoneEntry.ID>()

    @ObservationIgnored private var serial: String?
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var loadToken = 0

    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { path != PhoneFS.root && path != "/" }
    var selectedEntries: [PhoneEntry] { entries.filter { selection.contains($0.id) } }

    var crumbs: [(name: String, path: String)] {
        guard path.hasPrefix(PhoneFS.root) else { return [(path, path)] }
        var out = [("Phone", PhoneFS.root)]
        var acc = PhoneFS.root
        for part in path.dropFirst(PhoneFS.root.count).split(separator: "/") {
            acc += "/" + part
            out.append((String(part), acc))
        }
        return out
    }

    func attach(_ serial: String?) {
        guard serial != self.serial else { return }
        self.serial = serial
        guard let serial else { entries = []; return }
        refresh()
        DispatchQueue.global(qos: .utility).async {
            let checks = Place.all.map { "[ -d \($0.path.shQuoted) ] && echo \($0.path.shQuoted)" }.joined(separator: "; ")
            let existing = Set(((try? AdbClient.exec(serial, checks)) ?? "").split(separator: "\n").map(String.init))
            let space = PhoneFS.freeSpace(serial)
            onMain {
                var seen = Set<String>()
                self.places = Place.all.filter { existing.contains($0.path) && seen.insert($0.name).inserted }
                if self.places.isEmpty { self.places = [Place.all[0]] }
                self.freeSpace = space
            }
        }
    }

    func open(_ newPath: String) {
        guard newPath != path else { return }
        history.append(path)
        path = newPath
        selection = []
        refresh()
    }

    func open(_ e: PhoneEntry) { if e.isDirectory { open(e.path) } }
    func goUp() { if canGoUp { open((path as NSString).deletingLastPathComponent) } }
    func goBack() {
        guard let prev = history.popLast() else { return }
        path = prev
        selection = []
        refresh()
    }

    func refresh() {
        guard let serial else { return }
        loadToken += 1
        let token = loadToken, dir = path
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PhoneFS.list(serial, dir) }
            let space = PhoneFS.freeSpace(serial)
            onMain {
                guard token == self.loadToken else { return }
                self.loading = false
                self.freeSpace = space ?? self.freeSpace
                switch result {
                case .success(let e): self.entries = e; self.error = nil
                case .failure(let err): self.entries = []; self.error = err.localizedDescription
                }
            }
        }
    }

    func delete(_ items: [PhoneEntry]) {
        guard let serial else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? PhoneFS.delete(serial, items.map(\.path))
            onMain { self.refresh() }
        }
    }

    func newFolder(named name: String) {
        guard let serial, !name.isEmpty else { return }
        let target = path + "/" + name.replacingOccurrences(of: "/", with: "-")
        DispatchQueue.global(qos: .userInitiated).async {
            try? PhoneFS.makeFolder(serial, target)
            onMain { self.refresh() }
        }
    }
}
