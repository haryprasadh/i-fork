import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit
import Combine

private final class WifiDropErrorState: ObservableObject {
    @Published var message: String?
}

struct WifiDropView: View {
    private let server = WifiDropServer.shared
    @StateObject private var errorState = WifiDropErrorState()
    private let context = CIContext()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wi-Fi Drop").font(.title2.bold())
                        Text("Send files between this Mac and a phone on the same Wi-Fi network.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(server.isRunning ? "Stop" : "Start") {
                        if server.isRunning { server.stop() }
                        else { do { try server.start() } catch { errorState.message = error.localizedDescription } }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let url = server.url {
                    VStack(spacing: 12) {
                        if let image = qrCode(for: url.absoluteString) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 220, height: 220)
                                .accessibilityLabel("QR code for Wi-Fi Drop")
                        }
                        HStack(spacing: 8) {
                            Text(url.absoluteString).textSelection(.enabled).font(.callout.monospaced())
                                .lineLimit(2)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .help("Copy link")
                        }
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(server.bytesPerSecond), countStyle: .file))/s · \(server.activeTransfers) active")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text("Start to show a link and QR code.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                }

                section("Received") {
                    if server.received.isEmpty { Text("Files sent from your phone appear here.").foregroundStyle(.secondary) }
                    ForEach(server.received, id: \.self) { file in
                        HStack {
                            Image(systemName: "doc")
                            Text(file.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        }
                    }
                }

                section("Shared to phone") {
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up").font(.title2)
                        Text("Drop files or folders here")
                        ForEach(server.shared, id: \.self) { file in
                            HStack {
                                Text(file.lastPathComponent).lineLimit(1)
                                Spacer()
                                Button { server.unshare(file) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.plain).help("Remove")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    .dropDestination(for: URL.self) { urls, _ in server.share(urls); return !urls.isEmpty }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 540)
        .alert("Wi-Fi Drop", isPresented: Binding(get: { errorState.message != nil }, set: { if !$0 { errorState.message = nil } })) {
            Button("OK") { errorState.message = nil }
        } message: { Text(errorState.message ?? "") }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
    }

    private func qrCode(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
                  from: output.extent.applying(CGAffineTransform(scaleX: 10, y: 10))) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
