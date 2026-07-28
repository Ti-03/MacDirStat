import SwiftUI

enum DetailTab { case treemap, duplicates }

struct ContentView: View {
    @EnvironmentObject private var vm: ScanViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("showFileTree") private var userWantsTree = true
    @State private var scanHidesTree = false
    @State private var activeTab: DetailTab = .treemap
    @State private var showingSettings = false
    @AppStorage("defaultTab") private var defaultTab = "treemap"
    @AppStorage("treemapColorScheme") private var treemapColorScheme = "byType"
    @Namespace private var tabNamespace

    private var showTree: Bool { userWantsTree && !scanHidesTree }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            detailContent
        }
        .glassWindow()
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath else { return false }
            vm.scan(url: url)
            return true
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if activeTab == .treemap, vm.root != nil || vm.isScanning {
                    Button { vm.drillUp() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(vm.drillStack.isEmpty)

                    if let node = vm.treemapRoot {
                        FolderTitleView(url: node.url)
                    }
                }
            }

            // Tab switcher — center of toolbar
            ToolbarItem(placement: .principal) {
                if vm.root != nil || vm.isScanning || vm.isComputingLayout {
                    tabPicker
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if activeTab == .treemap {
                    if vm.root != nil {
                        Button {
                            userWantsTree.toggle()
                        } label: {
                            Image(systemName: "sidebar.left")
                                .symbolVariant(showTree ? .none : .slash)
                        }
                        .help(showTree ? "Hide file list" : "Show file list")
                    }
                }

                if vm.isScanning || vm.isComputingLayout {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if vm.isScanning {
                            Text("\(vm.itemsScanned) items")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(ByteFormatter.string(from: vm.bytesFound))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Button("Cancel") { vm.cancelScan() }
                                .foregroundStyle(.red)
                        } else {
                            Text("Building treemap…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassCapsule()
                    .transition(.opacity)
                } else {
                    Button("Open Folder…") { openFolderPicker(vm: vm) }
                        .glassProminentButton()
                }

                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                }
                .help("Settings & About")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    // Passed explicitly rather than relying on the popover
                    // inheriting it, so the Permissions section can't crash
                    // looking for a missing environment object.
                    DashboardSettingsView().environmentObject(vm)
                }
            }
        }
        .onChange(of: vm.isScanning) { scanning in
            scanHidesTree = scanning
            if scanning { activeTab = .treemap }
        }
        .onChange(of: treemapColorScheme) { _ in vm.refreshLayout() }
        .onAppear {
            if defaultTab == "duplicates" { activeTab = .duplicates }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportCSV)) { _ in
            vm.exportCSV()
        }
        .sheet(isPresented: $vm.showFDASheet) {
            FullDiskAccessSheet()
        }
        .sheet(isPresented: $vm.showComparisonSheet) {
            ComparisonView()
        }
    }

    // MARK: - Tab picker

    @ViewBuilder
    private var tabPicker: some View {
        HStack(spacing: 0) {
            tabButton(tab: .treemap,    icon: "square.3.layers.3d", label: "Treemap")
            tabButton(tab: .duplicates, icon: "doc.on.doc",          label: "Duplicates",
                      badge: duplicatesBadge, detecting: !vm.duplicatesReady && vm.root != nil)
        }
        .padding(3)
        .glassCard(cornerRadius: 10)
        .fixedSize()
    }

    private var duplicatesBadge: String? {
        guard vm.duplicatesReady, !vm.isScanning else { return nil }
        let n = vm.duplicateGroups.count
        return n > 0 ? "\(n)" : nil
    }

    @ViewBuilder
    private func tabButton(
        tab: DetailTab,
        icon: String,
        label: String,
        badge: String? = nil,
        detecting: Bool = false
    ) -> some View {
        let isActive = activeTab == tab

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { activeTab = tab }
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    if detecting {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(width: 14, height: 14)

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.primary.opacity(0.12))
                        .matchedGeometryEffect(id: "tabHighlight", in: tabNamespace)
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(tab == .duplicates && vm.root == nil && !detecting)
    }

    // MARK: - Detail content

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if vm.isReadOnlySnapshot {
                SnapshotBanner(date: vm.snapshotDate)
            }
            if !vm.hasFullDiskAccess || (vm.deniedCount > 0 && !vm.isScanning) {
                FullDiskAccessBanner(hasFullDiskAccess: vm.hasFullDiskAccess, deniedCount: vm.deniedCount) {
                    vm.showFDASheet = true
                }
            }
            if vm.root == nil && !vm.isScanning && !vm.isComputingLayout {
                WelcomeView()
            } else if activeTab == .duplicates {
                duplicatesContent
            } else {
                treemapContent
            }
        }
    }

    @ViewBuilder
    private var treemapContent: some View {
        VStack(spacing: 0) {
            if showTree {
                HSplitView {
                    DirectoryTreeView()
                        .frame(minWidth: 220, idealWidth: 300)
                    TreemapView()
                        .frame(minWidth: 300)
                }
            } else {
                TreemapView()
            }
            Divider()
            ExtensionListView()
                .frame(height: 84)
        }
    }

    @ViewBuilder
    private var duplicatesContent: some View {
        if vm.root != nil && !vm.duplicatesReady {
            VStack(spacing: 16) {
                ProgressView()
                Text("Scanning for duplicates…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("This runs in the background — it may take a moment for large folders.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .padding(32)
            .glassCard(cornerRadius: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DuplicatesView()
        }
    }
}

// MARK: - Welcome screen

private struct WelcomeView: View {
    @EnvironmentObject private var vm: ScanViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    // Dark mode: deep indigo/violet. Light mode: soft lavender/periwinkle pastels.
    private var gradientColors: [Color] {
        isDark ? [
            Color(hue: 0.67, saturation: 0.65, brightness: 0.28),
            Color(hue: 0.72, saturation: 0.75, brightness: 0.22),
            Color(hue: 0.62, saturation: 0.55, brightness: 0.32),
            Color(hue: 0.70, saturation: 0.70, brightness: 0.26),
            Color(hue: 0.65, saturation: 0.60, brightness: 0.38),
            Color(hue: 0.75, saturation: 0.65, brightness: 0.28),
            Color(hue: 0.62, saturation: 0.50, brightness: 0.24),
            Color(hue: 0.68, saturation: 0.75, brightness: 0.28),
            Color(hue: 0.72, saturation: 0.65, brightness: 0.26)
        ] : [
            Color(hue: 0.67, saturation: 0.28, brightness: 0.97),
            Color(hue: 0.72, saturation: 0.22, brightness: 0.99),
            Color(hue: 0.60, saturation: 0.20, brightness: 0.98),
            Color(hue: 0.70, saturation: 0.25, brightness: 0.96),
            Color(hue: 0.65, saturation: 0.18, brightness: 1.00),
            Color(hue: 0.75, saturation: 0.22, brightness: 0.97),
            Color(hue: 0.62, saturation: 0.20, brightness: 0.98),
            Color(hue: 0.68, saturation: 0.28, brightness: 0.95),
            Color(hue: 0.72, saturation: 0.22, brightness: 0.97)
        ]
    }

    var body: some View {
        ZStack {
            if #available(macOS 15, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        .init(0, 0), .init(0.5, 0), .init(1, 0),
                        .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                        .init(0, 1), .init(0.5, 1), .init(1, 1)
                    ],
                    colors: gradientColors
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LinearGradient(
                    colors: [gradientColors[0], gradientColors[4], gradientColors[8]],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 32) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 80, weight: .thin))
                    .foregroundStyle(.primary.opacity(0.85))
                    .symbolRenderingMode(.hierarchical)
                    .padding(24)
                    .glassCircle()

                VStack(spacing: 10) {
                    Text("DirStat")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Visualize your disk space usage at a glance")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Open Folder…") { openFolderPicker(vm: vm) }
                    .glassProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: .command)

                Text("Or drop a folder anywhere")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .glassCapsule()
            }
            .padding(48)
            .glassCard(cornerRadius: 28)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }
}

// MARK: - Folder title (compact — name + one parent level)

private struct FolderTitleView: View {
    let url: URL

    private var name: String { url.lastPathComponent }
    private var parent: String? {
        let p = url.deletingLastPathComponent().lastPathComponent
        return (p.isEmpty || p == "/") ? nil : p
    }

    var body: some View {
        HStack(spacing: 4) {
            if let parent {
                Text(parent)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassCapsule()
    }
}

// MARK: - Full Disk Access banner

private struct FullDiskAccessBanner: View {
    let hasFullDiskAccess: Bool
    let deniedCount: Int
    let onOpenSheet: () -> Void

    private let title = "Full Disk Access required for complete results"

    private var subtitle: String {
        if !hasFullDiskAccess {
            return "Go to System Settings → Privacy & Security → Full Disk Access and add DirStat."
        }
        let folders = deniedCount == 1 ? "1 folder" : "\(deniedCount) folders"
        return "\(folders) couldn't be read. Grant Full Disk Access for a complete scan."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings", action: onOpenSheet)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.15))
        .overlay(alignment: .bottom) { Divider().overlay(.orange.opacity(0.3)) }
    }
}

// MARK: - Read-only snapshot banner

// Shown whenever `vm.tree` was loaded from a `.mdscan` archive instead of a
// live scan. Trash/delete actions are already disabled at the ScanViewModel
// level (`trashNodes` no-ops while `isReadOnlySnapshot` is set); this is
// just the visible explanation of why.
private struct SnapshotBanner: View {
    let date: Date?

    private var subtitle: String {
        guard let date else { return "Opened from a saved scan. Delete actions are disabled." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Saved \(formatter.string(from: date)). Delete actions are disabled."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Read-only snapshot")
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.blue.opacity(0.15))
        .overlay(alignment: .bottom) { Divider().overlay(.blue.opacity(0.3)) }
    }
}

// MARK: - Dashboard settings popover

private struct DashboardSettingsView: View {
    @EnvironmentObject private var vm: ScanViewModel
    @AppStorage("hapticFeedbackEnabled") private var hapticEnabled = true
    @AppStorage("useBinarySize")         private var useBinarySize = false
    @AppStorage("showHiddenFiles")       private var showHiddenFiles = false
    @AppStorage("excludedFolderNames")   private var excludedFolderNames = ".git,node_modules,DerivedData,.Trash"
    @AppStorage("autoScanLastFolder")    private var autoScanLastFolder = false
    @AppStorage("realtimeMonitoring")    private var realtimeMonitoring = true
    @AppStorage("defaultTab")            private var defaultTab = "treemap"
    @AppStorage("treemapColorScheme")    private var treemapColorScheme = "byType"
    @AppStorage("showFileCount")         private var showFileCount = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                settingsSection("Appearance") {
                    row("File size units") {
                        Picker("", selection: $useBinarySize) {
                            Text("Decimal").tag(false)
                            Text("Binary").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    caption("Decimal: KB/MB/GB (1000-based). Binary: KiB/MiB/GiB (1024-based).")

                    row("Color scheme") {
                        Picker("", selection: $treemapColorScheme) {
                            Text("By Type").tag("byType")
                            Text("Rainbow").tag("rainbow")
                            Text("Mono").tag("monochrome")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    row("Default tab") {
                        Picker("", selection: $defaultTab) {
                            Text("Treemap").tag("treemap")
                            Text("Duplicates").tag("duplicates")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Toggle("Show item count on chart", isOn: $showFileCount)
                        .toggleStyle(.switch).controlSize(.small)
                }

                Divider()

                settingsSection("Files") {
                    Toggle("Show hidden files", isOn: $showHiddenFiles)
                        .toggleStyle(.switch).controlSize(.small)
                    caption("Include dot-files like .DS_Store and .git in scans.")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Excluded folders")
                            .font(.system(size: 12))
                        TextField("Comma-separated names", text: $excludedFolderNames)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        caption("Folder names to skip during scanning.")
                    }
                }

                Divider()

                settingsSection("Behaviour") {
                    Toggle("Auto-scan last folder on launch", isOn: $autoScanLastFolder)
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("Real-time monitoring", isOn: $realtimeMonitoring)
                        .toggleStyle(.switch).controlSize(.small)
                    caption("Watch for file changes after scanning (uses FSEvents).")
                }

                Divider()

                settingsSection("Permissions") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(vm.hasFullDiskAccess ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(vm.hasFullDiskAccess ? "Full Disk Access looks granted" : "Full Disk Access not granted")
                            .font(.system(size: 12))
                    }

                    // The grant is per exact copy of the app, so the surest
                    // route is dragging this bundle in rather than hunting for
                    // it with the "+" picker and possibly adding another build.
                    FullDiskAccessDragTile()

                    Button("Open Full Disk Access settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .controlSize(.small)

                    if vm.hasFullDiskAccess && vm.deniedCount > 0 {
                        caption("\(vm.deniedCount) folders were still unreadable in the last scan. If DirStat is already listed, remove it with “−” and drag this copy in again — macOS ties the grant to one exact copy.")
                    } else {
                        caption("Without it, protected folders scan as 0 bytes and land in “Hidden & Unreadable Space”.")
                    }
                }

                Divider()

                settingsSection("Trackpad") {
                    Toggle("Haptic feedback", isOn: $hapticEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    caption("Feel file weights as you explore. Requires Force Touch.")
                }

                Divider()


                VStack(spacing: 5) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 28, weight: .thin))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary.opacity(0.8))
                    Text("DirStat")
                        .font(.system(size: 13, weight: .semibold))
                    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("Version \(v)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Link("ti0.me", destination: URL(string: "http://ti0.me/")!)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .frame(width: 300, height: 520)
        // The grant can change while this popover is open (the user drags the
        // icon into System Settings and comes straight back), and macOS has no
        // notification for it, so re-probe on appear and then periodically.
        .onAppear { vm.recheckFullDiskAccess() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                vm.recheckFullDiskAccess()
            }
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            trailing()
        }
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Helpers

extension Notification.Name {
    static let exportCSV = Notification.Name("MacDirStat.exportCSV")
}

@MainActor
private func openFolderPicker(vm: ScanViewModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Scan"
    if panel.runModal() == .OK, let url = panel.url {
        vm.scan(url: url)
    }
}
