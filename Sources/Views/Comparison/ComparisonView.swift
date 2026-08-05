import SwiftUI

// "Compare Scans Over Time": shows the diff between the currently loaded
// tree and a `.mdscan` archive picked from disk (see
// `ScanViewModel.compareWithSavedScan(archiveURL:)` /
// `ScanComparison.compare(before:after:)`). Presented as a sheet from
// `ContentView`. Entirely read-only — no delete/trash affordance exists
// here, since either side of the comparison may be a stale snapshot that no
// longer matches what's actually on disk.
struct ComparisonView: View {
    @EnvironmentObject private var vm: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    private var result: ScanViewModel.ComparisonResult? { vm.comparisonResult }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let result {
                if result.changes.isEmpty {
                    CompatContentUnavailableView(
                        title: "No Changes Found",
                        systemImage: "checkmark.circle",
                        description: Text("This scan is identical to the saved snapshot.")
                    )
                } else {
                    summaryBar(changes: result.changes)
                    Divider()
                    changeList(changes: result.changes)
                }
            }
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Compare Scans")
                    .font(.system(size: 13, weight: .semibold))
                if let result {
                    Text("Saved \(dateString(result.beforeMetadata.scanDate)) vs. now — \(result.afterRootPath)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Summary bar

    private func summaryBar(changes: [ScanChange]) -> some View {
        let added = changes.filter { $0.kind == .added }.count
        let removed = changes.filter { $0.kind == .removed }.count
        let grew = changes.filter { $0.kind == .grew }.count
        let shrank = changes.filter { $0.kind == .shrank }.count
        let replaced = changes.filter { $0.kind == .replaced }.count
        let netDelta = changes.reduce(Int64(0)) { $0 + $1.delta }

        return HStack(spacing: 14) {
            summaryPill(count: added, label: "added", color: .green, icon: "plus.circle")
            summaryPill(count: removed, label: "removed", color: .red, icon: "minus.circle")
            summaryPill(count: grew, label: "grew", color: .orange, icon: "arrow.up.circle")
            summaryPill(count: shrank, label: "shrank", color: .teal, icon: "arrow.down.circle")
            if replaced > 0 {
                summaryPill(count: replaced, label: "replaced", color: .purple, icon: "arrow.triangle.swap")
            }

            Spacer()

            Label(signedByteString(netDelta), systemImage: netDelta >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(netDelta >= 0 ? .orange : .teal)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func summaryPill(count: Int, label: String, color: Color, icon: String) -> some View {
        if count > 0 {
            Label("\(count) \(label)", systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    private func signedByteString(_ delta: Int64) -> String {
        let sign = delta > 0 ? "+" : (delta < 0 ? "-" : "")
        return sign + ByteFormatter.string(from: abs(delta))
    }

    // MARK: - Change list

    private func changeList(changes: [ScanChange]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(changes) { change in
                    ChangeRow(change: change)
                    Divider().padding(.leading, 34)
                }
            }
        }
    }
}

// MARK: - Change row

private struct ChangeRow: View {
    let change: ScanChange

    private var icon: String {
        switch change.kind {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .grew: return "arrow.up.circle.fill"
        case .shrank: return "arrow.down.circle.fill"
        case .replaced: return "arrow.triangle.swap"
        }
    }

    private var color: Color {
        switch change.kind {
        case .added: return .green
        case .removed: return .red
        case .grew: return .orange
        case .shrank: return .teal
        case .replaced: return .purple
        }
    }

    private var deltaString: String {
        let sign = change.delta > 0 ? "+" : (change.delta < 0 ? "-" : "")
        return sign + ByteFormatter.string(from: abs(change.delta))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 16)

            Image(systemName: change.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(change.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(change.relativePath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            switch change.kind {
            case .added:
                Text(ByteFormatter.string(from: change.afterSize))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .removed:
                Text(ByteFormatter.string(from: change.beforeSize))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .grew, .shrank, .replaced:
                Text("\(ByteFormatter.string(from: change.beforeSize)) → \(ByteFormatter.string(from: change.afterSize))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(deltaString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
