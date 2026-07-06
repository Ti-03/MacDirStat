import SwiftUI
import Sparkle

@main
struct MacDirStatApp: App {
    @StateObject private var vm = ScanViewModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("DirStat") {
            ContentView()
                .environmentObject(vm)
        }
        .defaultSize(width: 1200, height: 800)
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    openFolderPicker(vm: vm)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Export CSV…") {
                    NotificationCenter.default.post(name: .exportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
                Button("Visit Website") {
                    NSWorkspace.shared.open(URL(string: "https://ti-03.github.io/MacDirStat/")!)
                }
            }
            CommandGroup(after: .help) {
                Button("Grant Full Disk Access…") {
                    vm.showFDASheet = true
                }
            }
        }
    }
}

@MainActor
private func openFolderPicker(vm: ScanViewModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Scan"
    panel.message = "Choose a folder to analyze"
    if panel.runModal() == .OK, let url = panel.url {
        Task { @MainActor in vm.scan(url: url) }
    }
}
