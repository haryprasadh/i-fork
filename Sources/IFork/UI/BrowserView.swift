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
                Group {
                    if let err = browser.error {
                        ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(err))
                    } else if !browser.loading && browser.entries.isEmpty {
                        ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Drop files here to send them to your phone."))
                    }
                }
                .allowsHitTesting(false)
            }
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
        PhoneTable(
            entries: browser.entries,
            selection: Bindable(browser).selection,
            serial: phone.primary,
            onOpen: { browser.open($0) },
            onSave: { save($0) },
            onSaveAs: { chooseAndSave($0) },
            onDelete: { ui.confirmDelete = $0 },
            onDropFiles: { urls, folder in send(urls, into: folder) }
        )
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

    private func send(_ urls: [URL], into folder: String? = nil) {
        let dir = folder ?? browser.path
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
