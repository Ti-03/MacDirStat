import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var vm: ScanViewModel
    @State private var volumes: [URL] = []
    @AppStorage("recentPaths") private var recentPathsData: Data = Data()

    private var recentPaths: [URL] {
        ((try? JSONDecoder().decode([String].self, from: recentPathsData))
            .map { $0.compactMap { URL(fileURLWithPath: $0) } } ?? [])
            .filter { $0.path != "/" }
    }

    var body: some View {
        List {
            Section {
                ForEach(volumes, id: \.path) { vol in
                    VolumeRow(url: vol, isScanning: (vm.isScanning || vm.isComputingLayout) && vm.scanURL?.path == vol.path)
                        .onTapGesture {
                            guard vm.root?.url.path != vol.path else { return }
                            vm.scan(url: vol)
                        }
                }
            } header: {
                Label("Volumes", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !recentPaths.isEmpty {
                Section {
                    ForEach(recentPaths, id: \.path) { url in
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .onTapGesture {
                            guard vm.root?.url.path != url.path else { return }
                            vm.scan(url: url)
                        }
                    }
                } header: {
                    Label("Recent", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .animation(.easeInOut(duration: 0.3), value: vm.duplicatesReady)
        .onAppear { volumes = mountedVolumes() }
        .onChange(of: vm.root?.url) { url in
            guard let url else { return }
            addRecent(url: url)
        }
    }

    private func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    private func addRecent(url: URL) {
        var paths = recentPaths.map(\.path)
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        let trimmed = Array(paths.prefix(10))
        recentPathsData = (try? JSONEncoder().encode(trimmed)) ?? Data()
    }
}

private struct VolumeRow: View {
    let url: URL
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: volumeIcon)
                    .foregroundStyle(.blue)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(volumeName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if let total = totalSpace, let free = freeSpace {
                        Text("\(ByteFormatter.string(from: free)) free of \(ByteFormatter.string(from: total))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if let total = totalSpace, let free = freeSpace, total > 0 {
                let usedFraction = min(1.0, Double(total - free) / Double(total))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.5))
                            .frame(height: 5)
                        Capsule().fill(capacityColor(fraction: usedFraction))
                            .frame(width: max(0, g.size.width * usedFraction), height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .glassInteractiveCard(cornerRadius: 10)
    }

    private func capacityColor(fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .blue
    }

    private var volumeName: String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
    }

    private var volumeIcon: String {
        let removable = (try? url.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) ?? false
        return removable ? "externaldrive" : "internaldrive"
    }

    private var totalSpace: Int64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map { Int64($0) }
    }

    private var freeSpace: Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map { Int64($0) }
    }
}
