import Foundation

// Flat struct-of-arrays store for an entire scanned tree — the app-facing
// replacement for the `FSNode` class tree. One array entry per node, indexed
// by a plain `Int` (root is always index 0). This is the memory win over
// per-node class instances: no per-node URL/UUID/weak-parent-pointer
// overhead, and everything lives in a handful of contiguous arrays.
//
// Mutability split: `records` holds per-node fields that legitimately change
// after the initial scan assembly (duplicateGroupID, safetyLevel, size from a
// future refresh) and is mutated in place via the `set...(at:)` methods
// below. The topology arrays (parentIndex/childStart/childCount/childIndices)
// are immutable for the life of one `FileTree` instance — anything that needs
// to change the shape of the tree (e.g. appending the synthetic hidden-space
// node) produces a NEW `FileTree` instead (see `appendingSyntheticRootChild`).
public final class FileTree: @unchecked Sendable {
    public private(set) var records: [FileNodeRecord]
    let parentIndex: [Int]
    let childStart: [Int]
    let childCount: [Int]
    let childIndices: [Int]
    public let rootIndex: Int
    // The scanned root's own absolute path (not derivable from its name
    // alone) — `path(of:)` is this, plus the joined names of every node
    // between the root and the target index.
    public let rootPath: String

    public init(
        records: [FileNodeRecord],
        parentIndex: [Int],
        childStart: [Int],
        childCount: [Int],
        childIndices: [Int],
        rootIndex: Int,
        rootPath: String
    ) {
        self.records = records
        self.parentIndex = parentIndex
        self.childStart = childStart
        self.childCount = childCount
        self.childIndices = childIndices
        self.rootIndex = rootIndex
        self.rootPath = rootPath
    }

    // MARK: - Mutation (per-node fields only; topology never changes in place)

    public func setDuplicateGroupID(_ id: UUID?, at index: Int) {
        records[index].duplicateGroupID = id
    }

    public func setSafety(_ level: SafetyLevel, at index: Int) {
        records[index].safetyLevel = level
    }

    public func setSize(_ size: Int64, at index: Int) {
        records[index].size = size
    }

    // MARK: - Path reconstruction

    // Rebuilds the absolute path of `index` by walking parentIndex up to the
    // root and joining names, since individual records don't store a URL.
    public func path(of index: Int) -> String {
        guard index != rootIndex else { return rootPath }

        var components: [String] = []
        var current = index
        while current != rootIndex {
            components.append(records[current].name)
            let parent = parentIndex[current]
            guard parent >= 0 else { break }
            current = parent
        }

        let suffix = components.reversed().joined(separator: "/")
        return rootPath.hasSuffix("/") ? rootPath + suffix : rootPath + "/" + suffix
    }

    // MARK: - Synthetic hidden-space node

    // Returns a NEW tree with one extra leaf record appended as a child of
    // root, keeping root's children sorted size-desc (the invariant every
    // `FileNode.children` accessor relies on). Used for the "Hidden &
    // Unreadable Space" reconciliation entry appended after a volume-root
    // scan; see `ScanViewModel.appendHiddenSpaceNodeIfNeeded`.
    public func appendingSyntheticRootChild(name: String, size: Int64) -> FileTree {
        var newRecords = records
        newRecords[rootIndex].size += size
        let newNodeIndex = newRecords.count
        newRecords.append(FileNodeRecord(
            name: name,
            isDirectory: false,
            size: size,
            fileExtension: "",
            isSynthetic: true,
            safetyLevel: .danger
        ))

        var newParentIndex = parentIndex
        newParentIndex.append(rootIndex)

        // Root is index 0 by construction, and the builder lays out child
        // spans in index order, so root's span is always the very first one
        // in `childIndices` — inserting into it only requires shifting every
        // later span's start by one; root's own start never moves.
        let rootStart = childStart[rootIndex]
        let rootCount = childCount[rootIndex]
        let rootChildrenEnd = rootStart + rootCount

        var rootChildren = Array(childIndices[rootStart..<rootChildrenEnd])
        let insertAt = rootChildren.firstIndex { newRecords[$0].size < size } ?? rootChildren.count
        rootChildren.insert(newNodeIndex, at: insertAt)

        var newChildIndices = childIndices
        newChildIndices.replaceSubrange(rootStart..<rootChildrenEnd, with: rootChildren)

        var newChildStart = childStart
        var newChildCount = childCount
        newChildCount[rootIndex] += 1
        for i in 0..<newChildStart.count where i != rootIndex && newChildStart[i] >= rootChildrenEnd {
            newChildStart[i] += 1
        }

        return FileTree(
            records: newRecords,
            parentIndex: newParentIndex,
            childStart: newChildStart,
            childCount: newChildCount,
            childIndices: newChildIndices,
            rootIndex: rootIndex,
            rootPath: rootPath
        )
    }
}
