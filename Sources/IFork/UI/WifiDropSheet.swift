import SwiftUI

/// Hosts the Wi-Fi lane UI in a sheet and auto-starts the server so the QR is ready instantly.
struct WifiDropSheet: View {
    var body: some View {
        VStack(spacing: 0) {
            WifiDropView()
            Divider()
            HStack {
                Text("Phone and Mac must be on the same Wi-Fi. No app or USB debugging needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { UIState.shared.showWifiDrop = false }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 620)
        .onAppear {
            let server = WifiDropServer.shared
            if !server.isRunning { try? server.start() }
        }
    }
}
