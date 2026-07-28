import SwiftUI
import AppKit

/// Guided Full Disk Access onboarding. macOS provides no API to grant FDA
/// programmatically, so the best achievable flow is: explain what's blocked and why,
/// jump straight to the right System Settings pane, detect the grant while the sheet
/// is open, then offer to relaunch (required for the new permission to take effect)
/// and auto-resume the scan the user was on.
struct FullDiskAccessSheet: View {
    @EnvironmentObject private var vm: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    // Whether the access probe already claimed success at the moment this
    // sheet opened. Captured once, so a grant can be told apart from a probe
    // that was simply wrong to begin with.
    @State private var accessWasMissingOnOpen: Bool?
    // Drives the gentle up/down hint on the draggable icon.
    @State private var bobbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            if Self.showsGrantedState(accessWasMissingOnOpen: accessWasMissingOnOpen, hasAccessNow: vm.hasFullDiskAccess) {
                grantedState
            } else {
                missingState
            }
        }
        .padding(28)
        .frame(width: 460)
        .onAppear {
            if accessWasMissingOnOpen == nil { accessWasMissingOnOpen = !vm.hasFullDiskAccess }
        }
        .task {
            // Poll for a live permission change while the sheet is on screen — macOS
            // has no notification for TCC grants, so this is the only way to react
            // to the user flipping the toggle in System Settings without closing us.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                vm.recheckFullDiskAccess()
            }
        }
    }

    /// "Access granted!" is only honest for a grant this sheet actually watched
    /// happen: the probe said no when the sheet opened, and says yes now.
    ///
    /// The probe (is the TCC database readable) is not a reliable proxy for
    /// "this build can read the user's files". It can report success while the
    /// scan is still being denied hundreds of folders — which is exactly when
    /// the user opens this sheet from the warning banner. Keying off the
    /// probe's current value alone put them in a dead end: a congratulations
    /// screen whose only action is a relaunch that changes nothing, with no way
    /// to reach the System Settings button they were promised.
    ///
    /// So when the probe already claims access on open, show the instructions
    /// instead. Nothing is lost: if access really is fine, the banner that led
    /// here would not be showing.
    static func showsGrantedState(accessWasMissingOnOpen: Bool?, hasAccessNow: Bool) -> Bool {
        guard let accessWasMissingOnOpen else { return false }
        return accessWasMissingOnOpen && hasAccessNow
    }

    // MARK: - State A: access missing

    private var missingState: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .padding(22)
                .glassTintedCard(tint: .accentColor, cornerRadius: 200)

            VStack(spacing: 8) {
                Text("See your whole disk")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(explainerBody)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            steps

            VStack(spacing: 10) {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .keyboardShortcut(.defaultAction)
                .glassProminentButton()
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Not Now") { dismiss() }
                    .glassButton()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                // Fallback for anyone who would rather drag from a Finder
                // window, and a way to see exactly which copy is running when
                // several builds are floating around.
                Button("Show this app in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.runningAppURL()])
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

                Button("Don't ask again") {
                    UserDefaults.standard.set(true, forKey: "fdaPromptSuppressed")
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var explainerBody: String {
        let base = "macOS protects some folders (Documents, Desktop, other apps' data) until you grant Full Disk Access. MacDirStat reads sizes only — nothing is modified, collected, or sent anywhere."
        guard vm.deniedCount > 0 else { return base }
        let folders = vm.deniedCount == 1 ? "1 folder was" : "\(vm.deniedCount) folders were"
        var text = "\(base) \(folders) blocked during your last scan."
        // The confusing case: the toggle looks on, but folders are still
        // blocked. macOS ties the grant to the exact signed copy of the app,
        // so a rebuilt, re-signed, or moved copy inherits nothing from the
        // entry already in the list — it just sits there looking enabled.
        if vm.hasFullDiskAccess {
            text += " If MacDirStat already appears enabled in the list, remove it with the “−” button and add this copy again — macOS ties the grant to one exact copy of the app."
        }
        return text
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepRow(1, "Open System Settings")
            stepRow(2, "Drag this icon into the list")
            dragTile
            stepRow(3, "Make sure its switch is on, then come back")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }

    private var dragTile: some View { FullDiskAccessDragTile() }

    /// URL of the bundle that is actually running — the thing that needs the
    /// grant. Kept in one place so the drag payload and the Finder fallback
    /// can never disagree about which copy they mean.
    static func runningAppURL() -> URL { Bundle.main.bundleURL }

    static func runningAppName() -> String {
        Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    static func runningAppIcon() -> NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - State B: access granted, needs relaunch

    private var grantedState: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)
                .padding(22)
                .glassTintedCard(tint: .green, cornerRadius: 200)

            VStack(spacing: 8) {
                Text("Access granted!")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("MacDirStat needs to relaunch for macOS to apply the new permission. It will rescan automatically.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button("Relaunch & Rescan") {
                    vm.relaunchForFullDiskAccess()
                }
                .keyboardShortcut(.defaultAction)
                .glassProminentButton()
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Later") { dismiss() }
                    .glassButton()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The running app's own icon, draggable straight into the Full Disk Access
/// list in System Settings.
///
/// Better than the "+" button for a reason that bit a real user: macOS grants
/// access to one exact copy of an app, and the file picker happily adds a
/// different copy (an older build in /Applications, say) which then sits in
/// the list looking enabled while the copy actually running gets nothing.
/// Dragging carries this bundle's own URL, so the entry that lands in the list
/// is unambiguously the app the user is looking at.
///
/// Shared by the guided sheet and the Permissions section of Settings, so the
/// two can never drift apart about which copy they hand over.
struct FullDiskAccessDragTile: View {
    @State private var bobbing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: FullDiskAccessSheet.runningAppIcon())
                .resizable()
                .frame(width: 46, height: 46)
                .offset(y: bobbing ? -3 : 3)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: bobbing
                )
                .onDrag {
                    // The payload is this bundle's URL, so System Settings
                    // registers precisely the running copy.
                    NSItemProvider(object: FullDiskAccessSheet.runningAppURL() as NSURL)
                }
                .help("Drag me into the Full Disk Access list")

            VStack(alignment: .leading, spacing: 3) {
                Text(FullDiskAccessSheet.runningAppName())
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Drag me into the list")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.tint.opacity(0.55))
        )
        .onAppear { bobbing = true }
    }
}
