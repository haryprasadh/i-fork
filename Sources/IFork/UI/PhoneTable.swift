import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Native NSTableView for the phone's files.
/// Uses NSFilePromiseProvider for drag-to-Finder (the reliable path) and accepts file drops from Finder.
struct PhoneTable: NSViewRepresentable {
    let entries: [PhoneEntry]
    @Binding var selection: Set<String>
    let serial: String
    var onOpen: (PhoneEntry) -> Void
    var onSave: ([PhoneEntry]) -> Void
    var onSaveAs: ([PhoneEntry]) -> Void
    var onDelete: ([PhoneEntry]) -> Void
    var onDropFiles: (_ urls: [URL], _ intoFolder: String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", "Name", 380.0), ("size", "Size", 90.0), ("date", "Modified", 170.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.minWidth = id == "name" ? 200 : 70
            table.addTableColumn(col)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL])
        table.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.coordinator = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let changed = c.parent.entries.map(\.id) != entries.map(\.id) || c.parent.serial != serial
        c.parent = self
        guard let table = c.table else { return }
        if changed { table.reloadData(); table.scrollRowToVisible(0) }
        let want = IndexSet(entries.enumerated().filter { selection.contains($0.element.id) }.map(\.offset))
        if table.selectedRowIndexes != want { table.selectRowIndexes(want, byExtendingSelection: false) }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
        var parent: PhoneTable
        weak var table: KeyTableView?
        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.maxConcurrentOperationCount = 3
            q.qualityOfService = .userInitiated
            return q
        }()

        init(_ p: PhoneTable) { parent = p }

        var selected: [PhoneEntry] {
            guard let t = table else { return [] }
            return t.selectedRowIndexes.compactMap { $0 < parent.entries.count ? parent.entries[$0] : nil }
        }

        /// Clicked row if it's outside the selection, else the selection (Finder behaviour).
        var targets: [PhoneEntry] {
            guard let t = table else { return [] }
            let r = t.clickedRow
            if r >= 0, r < parent.entries.count, !t.selectedRowIndexes.contains(r) { return [parent.entries[r]] }
            return selected
        }

        // Data
        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let col = tableColumn, row < parent.entries.count else { return nil }
            let e = parent.entries[row]
            let id = col.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = e.name
                cell.imageView?.image = Self.icon(for: e)
            case "size":
                cell.textField?.stringValue = e.isDirectory ? "—" : Fmt.bytes(e.size)
            default:
                cell.textField?.stringValue = Fmt.date.string(from: e.modified)
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            if id.rawValue != "name" { text.textColor = .secondaryLabelColor; text.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                let img = NSImageView()
                img.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(img)
                cell.imageView = img
                NSLayoutConstraint.activate([
                    img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    img.widthAnchor.constraint(equalToConstant: 18), img.heightAnchor.constraint(equalToConstant: 18),
                    text.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 7),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            let ids = Set(selected.map(\.id))
            if ids != parent.selection { parent.selection = ids }
        }

        @objc func doubleClicked() {
            guard let t = table, t.clickedRow >= 0, t.clickedRow < parent.entries.count else { return }
            let e = parent.entries[t.clickedRow]
            if e.isDirectory { parent.onOpen(e) } else { parent.onSave([e]) }
        }

        func keyAction(_ key: KeyTableView.Key) {
            let items = selected
            guard !items.isEmpty else { return }
            switch key {
            case .delete: parent.onDelete(items)
            case .enter: if items.count == 1, items[0].isDirectory { parent.onOpen(items[0]) } else { parent.onSave(items) }
            }
        }

        // Context menu
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let items = targets
            guard !items.isEmpty else { return }
            if items.count == 1, items[0].isDirectory { menu.addItem(item("Open") { self.parent.onOpen(items[0]) }) }
            menu.addItem(item("Save to \(UIState.shared.saveDir.lastPathComponent)") { self.parent.onSave(items) })
            menu.addItem(item("Save to…") { self.parent.onSaveAs(items) })
            menu.addItem(.separator())
            menu.addItem(item("Delete…") { self.parent.onDelete(items) })
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let mi = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
            mi.handler = action
            mi.target = mi
            return mi
        }

        // Drag out: one file promise per row
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < parent.entries.count else { return nil }
            let e = parent.entries[row]
            let type = e.isDirectory ? UTType.folder : (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data)
            let p = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            p.userInfo = ["path": e.path, "name": e.name, "dir": e.isDirectory, "serial": parent.serial]
            return p
        }

        func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            (p.userInfo as? [String: Any])?["name"] as? String ?? "file"
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

        /// Runs on promiseQueue (background). Pulls the file/folder straight to Finder's destination.
        func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let info = p.userInfo as? [String: Any], let path = info["path"] as? String,
                  let serial = info["serial"] as? String else { completionHandler(nil); return }
            let isDir = info["dir"] as? Bool ?? false
            do {
                let sync = try AdbSync(serial: serial)
                defer { sync.quit() }
                let files = isDir ? try PhoneFS.listRecursive(serial, path) : []
                if isDir {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    for f in files {
                        let rel = String(f.path.dropFirst(path.count).drop(while: { $0 == "/" }))
                        try sync.pull(f.path, to: url.appendingPathComponent(rel), progress: { _ in }, isCancelled: { false })
                    }
                } else {
                    try sync.pull(path, to: url, progress: { _ in }, isCancelled: { false })
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        // Drop in: files from Finder
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] } // our own rows
            if op == .on, row >= 0, row < parent.entries.count, parent.entries[row].isDirectory { return .copy }
            tableView.setDropRow(-1, dropOperation: .on) // whole table = current folder
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            let folder = (row >= 0 && row < parent.entries.count && parent.entries[row].isDirectory) ? parent.entries[row].path : nil
            parent.onDropFiles(urls, folder)
            return true
        }

        static func icon(for e: PhoneEntry) -> NSImage {
            if e.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data)
        }
    }
}

/// NSTableView that forwards Delete and Return.
final class KeyTableView: NSTableView {
    enum Key { case delete, enter }
    weak var coordinator: PhoneTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: coordinator?.keyAction(.delete)
        case 36, 76: coordinator?.keyAction(.enter)
        default: super.keyDown(with: event)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}
