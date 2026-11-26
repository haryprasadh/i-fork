import SwiftUI

@main
struct IForkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() { Bench.runIfRequested() }

    var body: some Scene {
        WindowGroup("iFork") {
            RootView()
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Dev aid: `--ui-pull <remotePath> <localDir>` starts a download with the UI visible (for screenshots).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ui-pull"), args.count > i + 2 {
            let remote = args[i + 1], dir = URL(fileURLWithPath: args[i + 2])
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard let phone = DeviceMonitor.shared.phone, phone.wifi != nil || !DeviceMonitor.shared.useWifiLane else { return }
                    t.invalidate()
                    DispatchQueue.global().async {
                        let parent = (remote as NSString).deletingLastPathComponent
                        guard let e = (try? PhoneFS.list(phone.primary, parent))?.first(where: { $0.path == remote }) else { return }
                        onMain {
                            TransferCenter.shared.download([e], from: phone, to: dir)
                            if let job = TransferCenter.shared.current { UIState.shared.expandedJobs.insert(job.id) }
                        }
                    }
                }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
