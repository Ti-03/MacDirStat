import SwiftUI

struct ExtensionListView: View {
    @EnvironmentObject private var vm: ScanViewModel
    @State private var showAllPopover = false
    @State private var searchText = ""

    private let topN = 5

    // Show selected item, or fall back to the current chart root
    private var displayNode: FileNode? { vm.selectedNode ?? vm.treemapRoot }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            legendBar
        }
        .background(.thinMaterial)
    }

    // MARK: - Path bar

    @ViewBuilder
    private var pathBar: some View {
        if let node = displayNode {
            HStack(spacing: 0) {
                // Icon
                Image(systemName: FileTypeIcon.systemName(for: node))
                    .foregroundStyle(FileTypeIcon.color(for: node))
                    .font(.system(size: 16))
                    .frame(width: 28)

                // Path — takes all available width, truncates in the middle
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.url.path)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    HStack(spacing: 14) {
                        Label(ByteFormatter.string(from: node.size),
                              systemImage: "internaldrive")
                            .monospacedDigit()
                        if node.isDirectory {
                            Label("\(node.children.count) items",
                                  systemImage: "folder")
                        } else if !node.fileExtension.isEmpty {
                            Text(".\(node.fileExtension.uppercased())")
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary,
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                // Quick-action buttons
                HStack(spacing: 4) {
                    iconButton("doc.on.doc.fill", help: "Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.url.path, forType: .string)
                    }
                    iconButton("folder.fill", help: "Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Legend bar

    private var legendBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.extensionSummaries.prefix(topN)) { item in
                    ExtLegendPill(
                        item: item,
                        isActive: vm.highlightedExtension == item.id
                    )
                    .onTapGesture {
                        let next: String? = vm.highlightedExtension == item.id ? nil : item.id
                        vm.highlight(extension: next)
                    }
                }

                // "Show more" opens a popover listing every extension
                if vm.extensionSummaries.count > topN {
                    Button {
                        showAllPopover = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                            Text("\(vm.extensionSummaries.count - topN) more")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .glassButton()
                    .controlSize(.small)
                    .popover(isPresented: $showAllPopover, arrowEdge: .bottom) {
                        allExtensionsPopover
                            .onDisappear { searchText = "" }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
    }

    // MARK: - All-extensions popover

    private var filteredSummaries: [ScanViewModel.ExtensionSummary] {
        guard !searchText.isEmpty else { return vm.extensionSummaries }
        let q = searchText.lowercased()
        return vm.extensionSummaries.filter { $0.ext.lowercased().contains(q) }
    }

    private var allExtensionsPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All File Types")
                    .font(.headline)
                    .padding(.leading, 14)
                Spacer()
                Button { showAllPopover = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 1, pinnedViews: []) {
                    ForEach(filteredSummaries) { item in
                        let isActive = vm.highlightedExtension == item.id
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.color)
                                .frame(width: 12, height: 12)

                            Text(item.ext)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minWidth: 70, alignment: .leading)

                            Spacer()

                            Text("\(item.fileCount) files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)

                            Text(ByteFormatter.string(from: item.totalSize))
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 68, alignment: .trailing)

                            Text(String(format: "%.1f%%", item.percentage))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.color)
                                .frame(width: 42, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            isActive ? item.color.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let next: String? = vm.highlightedExtension == item.id ? nil : item.id
                            vm.highlight(extension: next)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 360, height: 440)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
        }
        .glassButton()
        .controlSize(.small)
        .help(help)
    }
}

// MARK: - Extension pill (legend chip)

private struct ExtLegendPill: View {
    let item: ScanViewModel.ExtensionSummary
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(item.color)
                .frame(width: 7, height: 7)

            Text(item.ext)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)

            // Mini bar showing proportion
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(item.color.opacity(0.18))
                        .frame(height: 4)
                    Capsule().fill(item.color.opacity(0.7))
                        .frame(width: g.size.width * item.percentage / 100, height: 4)
                }
            }
            .frame(width: 36, height: 4)

            Text(String(format: "%.0f%%", item.percentage))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? item.color : .secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassTintedInteractiveCapsule(tint: isActive ? item.color.opacity(0.4) : Color.clear)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}
