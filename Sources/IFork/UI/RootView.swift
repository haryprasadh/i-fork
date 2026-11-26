import SwiftUI

struct RootView: View {
    private let devices = DeviceMonitor.shared
    private let browser = BrowserModel.shared
    private let ui = UIState.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(browser: browser)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let phone = devices.phone {
                    BrowserView(browser: browser, phone: phone)
                } else {
                    SetupView()
                }
                TransferBar()
            }
        }
        .onAppear { devices.start() }
        .onChange(of: devices.phone?.primary, initial: true) { _, serial in browser.attach(serial) }
        .sheet(isPresented: Bindable(ui).showWifiDrop) { WifiDropSheet() }
    }
}

struct Sidebar: View {
    let browser: BrowserModel
    private let devices = DeviceMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            List {
                if devices.phone != nil {
                    Section("Places") {
                        ForEach(browser.places) { place in
                            Button { browser.open(place.path) } label: {
                                Label(place.name, systemImage: place.icon)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                            .listRowBackground(
                                browser.path == place.path
                                    ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 8)
                                    : nil
                            )
                        }
                    }
                }
                Section("Wireless") {
                    Button { UIState.shared.showWifiDrop = true } label: {
                        Label("Wi-Fi Drop (QR)", systemImage: "qrcode")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)

            VStack(spacing: 8) {
                if let phone = devices.phone { DeviceCard(phone: phone, browser: browser) }
                MacCard()
            }
            .padding(10)
        }
        .onAppear { Stats.shared.start() }
        .onChange(of: devices.phone?.primary) { _, _ in Stats.shared.refresh() }
    }
}

struct DeviceCard: View {
    let phone: Phone
    let browser: BrowserModel
    private let devices = DeviceMonitor.shared
    private let stats = Stats.shared

    var body: some View {
        InfoCard(icon: "smartphone", title: phone.name, storage: stats.phoneStorage, memory: stats.phoneRAM) {
            HStack(spacing: 6) {
                LaneChip(label: "USB", on: phone.usb != nil)
                LaneChip(label: "Wi-Fi", on: phone.wifi != nil && devices.useWifiLane)
                Spacer()
                Toggle("", isOn: Bindable(devices).useWifiLane).toggleStyle(.switch).controlSize(.mini)
                    .help("Use Wi-Fi alongside USB for extra speed")
            }
            if let hint = devices.wifiHint, phone.wifi == nil, devices.useWifiLane {
                Text(hint).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MacCard: View {
    private let stats = Stats.shared
    var body: some View {
        InfoCard(icon: "laptopcomputer", title: "This Mac", storage: stats.macStorage, memory: stats.macRAM) { EmptyView() }
            .help(stats.macVolume.isEmpty ? "" : "Storage of \(stats.macVolume), where iFork saves files")
    }
}

/// Shared card: name, storage bar, memory bar, optional extra content.
struct InfoCard<Extra: View>: View {
    let icon: String
    let title: String
    let storage: Usage?
    let memory: Usage?
    var storageLabel = "Storage"
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 22)
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            UsageRow(label: storageLabel, usage: storage, text: storage.map { "\(Fmt.short($0.free)) free of \(Fmt.short($0.total))" },
                     warn: (storage?.fraction ?? 0) > 0.9)
            UsageRow(label: "Memory", usage: memory, text: memory.map { "\(Fmt.gb($0.used)) of \(Fmt.gb($0.total)) used" },
                     warn: (memory?.fraction ?? 0) > 0.85)
            extra()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UsageRow: View {
    let label: String
    let usage: Usage?
    let text: String?
    let warn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(text ?? "…").font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            ThinBar(fraction: usage?.fraction ?? 0, color: warn ? .orange : .accentColor)
        }
    }
}

struct LaneChip: View {
    let label: String
    let on: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(on ? .primary : .secondary)
    }
}

struct SetupView: View {
    private let devices = DeviceMonitor.shared

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: devices.needsAuthorization ? "hand.tap" : "cable.connector")
                .font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
            if devices.needsAuthorization {
                Text("Tap “Allow” on your phone").font(.title2.weight(.semibold))
                Text("Tick “Always allow from this computer” so you only do this once.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Connect your Android phone").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    Step(n: 1, text: "Plug the phone in with a USB cable")
                    Step(n: 2, text: "Settings › About phone › tap **Build number** 7 times")
                    Step(n: 3, text: "Settings › System › Developer options › turn on **USB debugging**")
                    Step(n: 4, text: "Optional, for extra speed: also turn on **Wireless debugging**")
                }
                .padding(18)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            if let err = devices.serverError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Divider().frame(width: 260)
            Button { UIState.shared.showWifiDrop = true } label: {
                Label("No cable? Use Wi-Fi Drop", systemImage: "qrcode")
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    struct Step: View {
        let n: Int
        let text: LocalizedStringKey
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)").font(.caption.bold()).frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.2)))
                Text(text)
            }
        }
    }
}
