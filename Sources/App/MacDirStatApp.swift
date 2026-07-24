import SwiftUI
import Sparkle
import UniformTypeIdentifiers

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

                Button("Open Scan…") {
                    openArchivePicker(vm: vm)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Save Scan…") {
                    saveScanPicker(vm: vm)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(vm.tree == nil)

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

// Not registered as a system-wide document type (no Info.plist exported-type
// entry) — `UTType(filenameExtension:)` gives macOS a dynamic UTI that's
// perfectly sufficient for filtering these two panels by the `.mdscan`
// extension without touching the app's document/type registration.
private let mdscanType = UTType(filenameExtension: "mdscan") ?? .data

@MainActor
private func saveScanPicker(vm: ScanViewModel) {
    guard let tree = vm.tree else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [mdscanType]
    panel.nameFieldStringValue = "\(tree.records[tree.rootIndex].name).mdscan"
    panel.message = "Save this scan to reopen later as a read-only snapshot"
    if panel.runModal() == .OK, let url = panel.url {
        vm.saveScan(to: url)
    }
}

@MainActor
private func openArchivePicker(vm: ScanViewModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [mdscanType]
    panel.prompt = "Open"
    panel.message = "Choose a saved scan to reopen as a read-only snapshot"
    if panel.runModal() == .OK, let url = panel.url {
        vm.openArchive(from: url)
    }
}
