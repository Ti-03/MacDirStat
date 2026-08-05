import Foundation

// Lightweight, app-facing handle into a `FileTree` — the replacement for
// `FSNode` everywhere outside the scanner's own internal build step. A
// `FileNode` is just a (tree, index) pair; every property reads through to
// the tree's flat storage, so copying a `FileNode` is cheap and many can
// exist for the same underlying record.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let tree: FileTree
    public let index: Int

    public init(tree: FileTree, index: Int) {
        self.tree = tree
        self.index = index
    }

    // Stable within one tree instance — sufficient for SwiftUI identity and
    // selection. Not globally unique across trees (e.g. before/after a
    // rescan replaces `tree` entirely), which mirrors how the rest of the UI
    // already treats a rescan as a clean slate.
    public var id: Int { index }

    public var name: String { tree.records[index].name }
    public var size: Int64 { tree.records[index].size }
    public var isDirectory: Bool { tree.records[index].isDirectory }
    public var fileExtension: String { tree.records[index].fileExtension }
    public var isAccessDenied: Bool { tree.records[index].isAccessDenied }
    public var isSynthetic: Bool { tree.records[index].isSynthetic }
    public var isAutoSummarized: Bool { tree.records[index].isAutoSummarized }
    public var descendantFileCount: Int { tree.records[index].descendantFileCount }
    public var hardLinkRef: HardLinkRef? { tree.records[index].hardLinkRef }
    public var duplicateGroupID: UUID? { tree.records[index].duplicateGroupID }
    public var safetyLevel: SafetyLevel { tree.records[index].safetyLevel }

    public var url: URL { URL(fileURLWithPath: tree.path(of: index)) }

    public var parent: FileNode? {
        let p = tree.parentIndex[index]
        return p >= 0 ? FileNode(tree: tree, index: p) : nil
    }

    // Pre-sorted size-desc — the builder (and the synthetic-node splice)
    // guarantee this, so no consumer ever needs to sort children itself.
    public var children: [FileNode] {
        let start = tree.childStart[index]
        let count = tree.childCount[index]
        guard count > 0 else { return [] }
        return (0..<count).map { FileNode(tree: tree, index: tree.childIndices[start + $0]) }
    }

    public var optionalChildren: [FileNode]? {
        guard isDirectory, tree.childCount[index] > 0 else { return nil }
        return children
    }

    // MARK: - Mutation (writes through to the shared tree)

    public func setDuplicateGroupID(_ id: UUID?) {
        tree.setDuplicateGroupID(id, at: index)
    }

    public func setSafety(_ level: SafetyLevel) {
        tree.setSafety(level, at: index)
    }

    // MARK: - Hashable / Equatable

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        ObjectIdentifier(lhs.tree) == ObjectIdentifier(rhs.tree) && lhs.index == rhs.index
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(tree))
        hasher.combine(index)
    }
}
