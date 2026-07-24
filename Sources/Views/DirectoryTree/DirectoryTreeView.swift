import SwiftUI

struct DirectoryTreeView: View {
    @EnvironmentObject private var vm: ScanViewModel

    var body: some View {
        Group {
            if let root = vm.root {
                List(root.children, children: \.optionalChildren) { node in
                    NodeRow(node: node, isSelected: vm.selectedNode?.id == node.id)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.select(node) }
                        .contextMenu {
                            Text(node.name).fontWeight(.semibold)
                            Text(ByteFormatter.string(from: node.size))
                                .foregroundStyle(.secondary)
                            Divider()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([node.url])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder.viewfinder")
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.url.path, forType: .string)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.clipboard")
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(node.name, forType: .string)
                            } label: {
                                Label("Copy Name", systemImage: "textformat")
                            }
                            if node.isDirectory {
                                Divider()
                                Button {
                                    vm.drillDown(into: node)
                                } label: {
                                    Label("Open in Chart", systemImage: "arrow.down.right.circle")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                if let _ = try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil),
                                   let root = vm.root {
                                    vm.scan(url: root.url)
                                }
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(.ultraThinMaterial)
            } else {
                ScanningPlaceholder(items: vm.itemsScanned, bytes: vm.bytesFound)
            }
        }
    }
}

private struct ScanningPlaceholder: View {
    let items: Int
    let bytes: Int64

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3)
            VStack(spacing: 4) {
                Text("Scanning…").font(.headline)
                Text("\(items) items · \(ByteFormatter.string(from: bytes))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut, value: items)
            }
        }
        .padding(28)
        .glassCard(cornerRadius: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NodeRow: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Icon
            Image(systemName: FileTypeIcon.systemName(for: node))
                .foregroundStyle(FileTypeIcon.color(for: node))
                .font(.system(size: 12))
                .frame(width: 14, alignment: .center)

            // Name — takes all available space, tail-truncated
            Text(node.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? .white : .primary)

            // Inline extension badge for files
            if !node.isDirectory, !node.fileExtension.isEmpty {
                Text(node.fileExtension.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.65) : Color.secondary.opacity(0.5))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1.5)
                    .background(
                        isSelected ? Color.white.opacity(0.15) : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .fixedSize()
            }

            Spacer(minLength: 4)

            // Safety indicator — only shown for safe (green) and danger (red), not caution
            if node.safetyLevel == .safe {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green.opacity(0.8))
                    .help(SafetyAnalyzer.reason(for: node) ?? "Safe to delete")
            } else if node.safetyLevel == .danger {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.8))
                    .help(SafetyAnalyzer.reason(for: node) ?? "Do not delete")
            }

            if node.isAccessDenied {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Contents couldn't be read — Full Disk Access may be required")
            }

            if node.isAutoSummarized {
                Text("(\(node.descendantFileCount) files, summarized)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.55) : Color.secondary.opacity(0.65))
                    .lineLimit(1)
                    .fixedSize()
                    .help("Collapsed to keep the scan fast: contents aren't browsable individually")
            }

            // Size
            Text(ByteFormatter.string(from: node.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()

            // Percentage of parent — fixed width so sizes stay aligned
            Text(percentageOfParent ?? "")
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.white.opacity(0.55) : Color.secondary.opacity(0.65))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
                .lineLimit(1)
                .opacity(percentageOfParent == nil ? 0 : 1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private var percentageOfParent: String? {
        guard let parentSize = node.parent?.size, parentSize > 0 else { return nil }
        let pct = Double(node.size) / Double(parentSize) * 100
        return pct >= 10 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }
}
