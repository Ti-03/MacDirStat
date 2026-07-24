import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject private var vm: ScanViewModel
    // Expanded state lives here so LazyVStack rows don't need @State on init
    @State private var expanded: Set<Int> = []

    var body: some View {
        let groups = vm.duplicateGroups
        if groups.isEmpty {
            CompatContentUnavailableView(
                title: "No Duplicates Found",
                systemImage: "checkmark.circle",
                description: Text("No duplicate files were detected")
            )
        } else {
            VStack(spacing: 0) {
                summaryBar(groups: groups)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            GroupSection(
                                index: index,
                                group: group,
                                isExpanded: expanded.contains(index),
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if expanded.contains(index) { expanded.remove(index) }
                                        else { expanded.insert(index) }
                                    }
                                },
                                onDeleteGroup: { deleteGroup(group) },
                                onDeleteNode: { deleteNode($0) }
                            )
                            Divider().padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Summary bar

    @ViewBuilder
    private func summaryBar(groups: [[FileNode]]) -> some View {
        let totalWasted = groups.reduce(Int64(0)) { $0 + $1[0].size * Int64($1.count - 1) }
        let totalFiles  = groups.reduce(0) { $0 + $1.count - 1 }

        HStack(spacing: 16) {
            Label("\(groups.count) groups", systemImage: "square.on.square")
                .font(.caption).foregroundStyle(.secondary)
            Label("\(totalFiles) duplicate files", systemImage: "doc.on.doc")
                .font(.caption).foregroundStyle(.secondary)
            Label(ByteFormatter.string(from: totalWasted) + " wasted",
                  systemImage: "externaldrive.badge.minus")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button(role: .destructive) { deleteAll(groups: groups) } label: {
                Label("Delete All Duplicates", systemImage: "trash")
                    .font(.caption.weight(.medium))
            }
            .glassButton()
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Delete helpers

    private func deleteAll(groups: [[FileNode]]) {
        guard let rootURL = vm.root?.url else { return }
        var deleted = false
        for group in groups {
            for node in group.dropFirst() {
                if (try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)) != nil {
                    deleted = true
                }
            }
        }
        if deleted { vm.scan(url: rootURL) }
    }

    private func deleteGroup(_ group: [FileNode]) {
        guard let rootURL = vm.root?.url else { return }
        var deleted = false
        for node in group.dropFirst() {
            if (try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)) != nil {
                deleted = true
            }
        }
        if deleted { vm.scan(url: rootURL) }
    }

    private func deleteNode(_ node: FileNode) {
        guard let rootURL = vm.root?.url else { return }
        if (try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)) != nil {
            vm.scan(url: rootURL)
        }
    }
}

// MARK: - Group section (value type — no @State, safe for LazyVStack)

private struct GroupSection: View {
    let index: Int
    let group: [FileNode]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDeleteGroup: () -> Void
    let onDeleteNode: (FileNode) -> Void

    private var wasted: Int64 { group[0].size * Int64(group.count - 1) }

    var body: some View {
        VStack(spacing: 0) {
            // Header row — always visible
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)

                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)

                    Text("\(group.count) identical copies")
                        .font(.system(size: 12, weight: .semibold))

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Text(ByteFormatter.string(from: wasted) + " wasted")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Spacer()

                    // Show one filename as a hint when collapsed
                    if !isExpanded {
                        Text(group[0].name)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .trailing)
                    }

                    Button(role: .destructive, action: onDeleteGroup) {
                        Label("Keep 1, Delete \(group.count - 1)", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .glassButton()
                    .tint(.red)
                    .controlSize(.mini)
                    // Don't let the delete button trigger the expand toggle
                    .onTapGesture {}
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // File rows — only rendered when expanded
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.enumerated()), id: \.element.id) { i, node in
                        FileRow(node: node, isKeep: i == 0) { onDeleteNode(node) }
                        if i < group.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color.primary.opacity(0.02))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - File row

private struct FileRow: View {
    let node: FileNode
    let isKeep: Bool
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Keep / duplicate badge — fixed width so columns align
            Group {
                if isKeep {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "doc.badge.plus")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .frame(width: 16)
            .padding(.leading, 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(node.url.deletingLastPathComponent().path)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(ByteFormatter.string(from: node.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()

            if isKeep {
                Color.clear.frame(width: 24, height: 24)
            } else {
                Button(action: onDelete) {
                    Image(systemName: isHovered ? "trash.fill" : "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(isHovered ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .onHover { isHovered = $0 }
                .help("Move to Trash")
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
            if !isKeep {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
    }
}
