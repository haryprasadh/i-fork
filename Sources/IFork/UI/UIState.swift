import Foundation
import Observation

/// App-wide view state. Lives here (not in @State) because the Command Line Tools
/// toolchain lacks the SwiftUI macro plugin that @State needs on this SDK.
@MainActor @Observable final class UIState {
    static let shared = UIState()

    var showWifiDrop = false
    var dropTargeted = false
    var confirmDelete: [PhoneEntry] = []
    var askNewFolder = false
    var newFolderName = ""
    var dismissedJob: UUID?
    var saveDirPath: String = UserDefaults.standard.string(forKey: "saveDir")
        ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path {
        didSet { UserDefaults.standard.set(saveDirPath, forKey: "saveDir") }
    }
    var saveDir: URL { URL(fileURLWithPath: saveDirPath) }
}
