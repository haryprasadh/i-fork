import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BrowserView: View {
    let browser: BrowserModel
    let phone: Phone
    private let center = TransferCenter.shared
    private let ui = UIState.shared

    private var saveDir: URL { ui.saveDir }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            ZStack {
                table
                if browser.loading && browser.entries.isEmpty { ProgressView() }
                if let err = browser.error {
                    ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(err))
                } else if !browser.loading && browser.entries.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Drop files here to send them to your phone."))
                }
                if ui.dropTargeted { dropOverlay }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter { $0.isFileURL && !$0.path.contains("/iFork-drag-") }
                guard !files.isEmpty else { return false }
                send(files)
                return true
            } isTargeted: { ui.dropTargeted = $0 }
        }
        .toolbar { toolbar }
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { !ui.confirmDelete.isEmpty }, set: { if !$0 { ui.confirmDelete = [] } })) {
            Button("Delete", role: .destructive) { browser.delete(ui.confirmDelete); ui.confirmDelete = [] }
        } message: { Text("This can't be undone.") }
        .alert("New folder", isPresented: Bindable(ui).askNewFolder) {
            TextField("Name", text: Bindable(ui).newFolderName)
            Button("Create") { browser.newFolder(named: ui.newFolderName); ui.newFolderName = "" }
            Button("Cancel", role: .cancel) { ui.newFolderName = "" }
        }
    }

    private var deleteTitle: String {
        let items = ui.confirmDelete
        return "Delete \(items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items") from the phone?"
    }

    // MARK: pieces

    private var pathBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(browser.crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(c.name) { browser.open(c.path) }
                    .buttonStyle(.plain)
                    .font(i == browser.crumbs.count - 1 ? .callout.weight(.semibold) : .callout)
                    .foregroundStyle(i == browser.crumbs.count - 1 ? .primary : .secondary)
            }
            Spacer()
            if browser.loading { ProgressView().controlSize(.small) }
            Text("\(browser.entries.count) items").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var table: some View {
        Table(of: PhoneEntry.self, selection: Bindable(browser).selection) {
            TableColumn("Name") { e in
                HStack(spacing: 8) {
                    Image(nsImage: icon(for: e)).resizable().frame(width: 18, height: 18)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 220, ideal: 380)
            TableColumn("Size") { e in
                Text(e.isDirectory ? "—" : Fmt.bytes(e.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified") { e in
                Text(Fmt.date.string(from: e.modified)).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
        } rows: {
            ForEach(browser.entries) { e in
                TableRow(e).draggable(PhoneDragItem(entry: e, serial: phone.primary))
            }
        }
        .contextMenu(forSelectionType: PhoneEntry.ID.self) { ids in
            let items = browser.entries.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDirectory {
                Button("Open") { browser.open(items[0]) }
            }
            Button("Save to \(saveDir.lastPathComponent)") { save(items) }
            Button("Save to…") { chooseAndSave(items) }
            Divider()
            Button("Delete…", role: .destructive) { ui.confirmDelete = items }
        } primaryAction: { ids in
            let items = browser.entries.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDirectory { browser.open(items[0]) } else { save(items) }
        }
        .onDeleteCommand { if !browser.selectedEntries.isEmpty { ui.confirmDelete = browser.selectedEntries } }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08)))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line.circle.fill").font(.system(size: 44))
                    Text("Drop to send to \(phone.name)").font(.title3.weight(.semibold))
                    Text(browser.crumbs.map(\.name).joined(separator: " › ")).font(.callout).foregroundStyle(.secondary)
                }
                .foregroundStyle(.tint)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack).keyboardShortcut("[", modifiers: .command).help("Back")
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!browser.canGoUp).keyboardShortcut(.upArrow, modifiers: .command).help("Enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command).help("Refresh")
            Button { ui.askNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift]).help("New folder on phone")
            Button { pickAndSend() } label: { Label("Send to Phone", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("o", modifiers: .command).help("Send files from your Mac to this folder")
            Button { save(browser.selectedEntries) } label: { Label("Save to Mac", systemImage: "square.and.arrow.down") }
                .disabled(browser.selection.isEmpty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Copy the selection to \(saveDir.path)")
        }
    }

    // MARK: actions

    private func send(_ urls: [URL]) {
        let dir = browser.path
        center.upload(urls, to: phone, remoteDir: dir) { browser.refresh() }
    }

    private func pickAndSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Send"
        if panel.runModal() == .OK { send(panel.urls) }
    }

    private func save(_ items: [PhoneEntry], to dir: URL? = nil) {
        center.download(items, from: phone, to: dir ?? saveDir)
    }

    private func chooseAndSave(_ items: [PhoneEntry]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            ui.saveDirPath = url.path
            save(items, to: url)
        }
    }

    private func icon(for e: PhoneEntry) -> NSImage {
        if e.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (e.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}
