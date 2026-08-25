import SwiftUI
#if !APPSTORE
import Sparkle
#endif
import UniformTypeIdentifiers

/// Which distribution channel this binary was built for. The `APPSTORE`
/// compilation condition is set only by the AppStore build configuration.
///
/// App Store builds are sandboxed, which rules out two things the Developer ID
/// build relies on: Sparkle self-updates (App Review guideline 2.4.5) and Full
/// Disk Access (a sandboxed app can never hold it, so the onboarding flow would
/// send users to System Settings for nothing).
enum Build {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}

@main
struct MacDirStatApp: App {
    @StateObject private var vm = ScanViewModel()
    #if !APPSTORE
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

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

                Button("Compare With Saved Scan…") {
                    compareWithSavedScanPicker(vm: vm)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(vm.tree == nil)
            }
            CommandGroup(after: .appInfo) {
                #if !APPSTORE
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
                #endif
                Button("Visit Website") {
                    NSWorkspace.shared.open(URL(string: "https://ti-03.github.io/MacDirStat/")!)
                }
            }
            CommandGroup(after: .help) {
                if !Build.isAppStore {
                    Button("Grant Full Disk Access…") {
                        vm.showFDASheet = true
                    }
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

@MainActor
private func compareWithSavedScanPicker(vm: ScanViewModel) {
    guard vm.tree != nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [mdscanType]
    panel.prompt = "Compare"
    panel.message = "Choose a saved scan to compare against the current one"
    if panel.runModal() == .OK, let url = panel.url {
        vm.compareWithSavedScan(archiveURL: url)
    }
}
