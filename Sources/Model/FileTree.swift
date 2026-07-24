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

    // MARK: - Pruning (Move to Trash without a full rescan)

    // Returns a NEW tree with the subtree rooted at `index` removed (the root
    // itself can never be removed — returns `self` unchanged if asked to).
    // Thin wrapper over `removingSubtrees(at:)`, which already handles the
    // single-index case without any extra cost.
    public func removingSubtree(at index: Int) -> FileTree {
        removingSubtrees(at: [index])
    }

    // Returns a NEW tree with every subtree rooted at each of `indices`
    // removed — the "Delete All Duplicates" / "keep 1, delete N" case, where
    // several unrelated nodes are trashed at once.
    //
    // Single pass over all indices (not a fold of `removingSubtree` calls one
    // at a time): every seed's whole subtree is marked in one iterative DFS,
    // then `records`/`parentIndex`/children are rebuilt once from the
    // resulting old->new index map. This is O(n) total rather than O(n·k)
    // for k removed subtrees, while remaining just as simple to reason about
    // as folding would be (a fold is also correct here — just slower).
    public func removingSubtrees(at indices: [Int]) -> FileTree {
        let count = records.count

        // Mark every node in each seed's subtree as removed via an iterative
        // DFS over childIndices (explicit stack, not recursion, so this can't
        // stack-overflow on a very deep real-world tree).
        var removed = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for seed in indices where seed != rootIndex && seed >= 0 && seed < count && !removed[seed] {
            stack.append(seed)
        }
        while let i = stack.popLast() {
            if removed[i] { continue }
            removed[i] = true
            let start = childStart[i]
            let cnt = childCount[i]
            for offset in 0..<cnt {
                stack.append(childIndices[start + offset])
            }
        }

        // Nothing valid to remove (empty/out-of-range/root-only indices) —
        // return the same instance rather than a redundant identical copy.
        guard removed.contains(true) else { return self }

        // Old -> new index map over kept nodes, built in ascending old-index
        // order — this is what keeps every child span's relative order
        // (already size-desc) intact after dropping the removed entries.
        var oldToNew = [Int](repeating: -1, count: count)
        var newRecords: [FileNodeRecord] = []
        newRecords.reserveCapacity(count)
        for old in 0..<count where !removed[old] {
            oldToNew[old] = newRecords.count
            newRecords.append(records[old])
        }

        var newParentIndex = [Int](repeating: -1, count: newRecords.count)
        for old in 0..<count where !removed[old] {
            let newIdx = oldToNew[old]
            let oldParent = parentIndex[old]
            newParentIndex[newIdx] = oldParent >= 0 ? oldToNew[oldParent] : -1
        }

        // Subtract each removed subtree's root size from every one of its
        // ancestors. Only process seeds whose immediate parent is NOT itself
        // removed — if the parent is removed too, this seed is a descendant
        // of some other (higher) removed subtree root, and its size was
        // already folded into the ancestor chain when that higher seed was
        // processed, so subtracting again here would double-count. Also
        // de-dupe in case the same index appears more than once in `indices`.
        var processedRoots = Set<Int>()
        for seed in indices {
            guard seed != rootIndex, seed >= 0, seed < count, removed[seed] else { continue }
            let parent = parentIndex[seed]
            if parent >= 0 && removed[parent] { continue }
            guard processedRoots.insert(seed).inserted else { continue }

            let removedSize = records[seed].size
            var ancestorOld = parent
            while ancestorOld >= 0 {
                newRecords[oldToNew[ancestorOld]].size -= removedSize
                ancestorOld = parentIndex[ancestorOld]
            }
        }

        // Rebuild children arrays, dropping removed entries from each
        // surviving parent's span but keeping the rest in their original
        // (size-desc) relative order.
        var newChildIndices: [Int] = []
        newChildIndices.reserveCapacity(childIndices.count)
        var newChildStart = [Int](repeating: 0, count: newRecords.count)
        var newChildCount = [Int](repeating: 0, count: newRecords.count)
        for old in 0..<count where !removed[old] {
            let newIdx = oldToNew[old]
            newChildStart[newIdx] = newChildIndices.count
            let start = childStart[old]
            let cnt = childCount[old]
            var kept = 0
            for offset in 0..<cnt {
                let childOld = childIndices[start + offset]
                if !removed[childOld] {
                    newChildIndices.append(oldToNew[childOld])
                    kept += 1
                }
            }
            newChildCount[newIdx] = kept
        }

        return FileTree(
            records: newRecords,
            parentIndex: newParentIndex,
            childStart: newChildStart,
            childCount: newChildCount,
            childIndices: newChildIndices,
            rootIndex: oldToNew[rootIndex],
            rootPath: rootPath
        )
    }

    // MARK: - Splice (incremental live-refresh, replacing the full-rescan interim)

    // Returns a NEW tree where the subtree rooted at `index` is replaced
    // wholesale by `subtree`'s own nodes, reparented under `index`'s former
    // parent in the very same child slot. This is the live-refresh
    // counterpart to `removingSubtrees` above: instead of dropping a stale
    // subtree, it swaps in a freshly-rescanned replacement for it (produced
    // by re-walking just that one directory on disk — see
    // `ScanViewModel.splicedTree(afterChangeAt:in:)`), so a filesystem
    // change deep inside a huge tree only costs a rescan of the changed
    // directory, not the whole root.
    //
    // The root itself can never be replaced this way (mirrors
    // `removingSubtree`'s own root guard, returning `self` unchanged) — a
    // changed root is the caller's responsibility to detect ahead of time
    // and fall back to a full rescan for instead.
    public func replacingSubtree(at index: Int, with subtree: FileTree) -> FileTree {
        let count = records.count
        guard index != rootIndex, index >= 0, index < count else { return self }
        let oldParent = parentIndex[index]
        guard oldParent >= 0 else { return self } // unreachable given index != rootIndex, but defensive

        // Mark the stale subtree rooted at `index` (itself plus every
        // descendant) via the same iterative DFS `removingSubtrees` uses.
        var removed = [Bool](repeating: false, count: count)
        var stack: [Int] = [index]
        while let i = stack.popLast() {
            if removed[i] { continue }
            removed[i] = true
            let start = childStart[i]
            let cnt = childCount[i]
            for offset in 0..<cnt {
                stack.append(childIndices[start + offset])
            }
        }

        // Old -> new index map over surviving (kept) nodes, ascending
        // old-index order — identical compaction to `removingSubtrees`.
        var oldToNew = [Int](repeating: -1, count: count)
        var newRecords: [FileNodeRecord] = []
        newRecords.reserveCapacity(count + subtree.records.count)
        for old in 0..<count where !removed[old] {
            oldToNew[old] = newRecords.count
            newRecords.append(records[old])
        }

        // Append the freshly-rescanned replacement's own records right after
        // the kept ones; every subtree-local index is offset by this amount
        // in the merged arrays below.
        let offset = newRecords.count
        newRecords.append(contentsOf: subtree.records)

        var newParentIndex = [Int](repeating: -1, count: newRecords.count)
        for old in 0..<count where !removed[old] {
            let newIdx = oldToNew[old]
            let op = parentIndex[old]
            newParentIndex[newIdx] = op >= 0 ? oldToNew[op] : -1
        }
        for i in 0..<subtree.records.count {
            let subParent = subtree.parentIndex[i]
            // The subtree's own root (subParent == -1) reparents onto
            // `index`'s old parent in the outer tree; every other subtree
            // node keeps its subtree-local parent, just offset.
            newParentIndex[offset + i] = subParent >= 0 ? offset + subParent : oldToNew[oldParent]
        }

        // Ancestor sizes: fold in the difference between the new subtree
        // root's size and the stale one it's replacing, all the way up to
        // the root (positive or negative — the changed directory may have
        // grown or shrunk).
        let delta = subtree.records[subtree.rootIndex].size - records[index].size
        var ancestorOld = oldParent
        while ancestorOld >= 0 {
            newRecords[oldToNew[ancestorOld]].size += delta
            ancestorOld = parentIndex[ancestorOld]
        }

        // Children spans: every kept node keeps its surviving children in
        // their original relative order, except the replaced node's own
        // slot in its parent's span (which used to point at `index`), which
        // now points at the new subtree's root instead.
        var newChildIndices: [Int] = []
        newChildIndices.reserveCapacity(childIndices.count + subtree.childIndices.count)
        var newChildStart = [Int](repeating: 0, count: newRecords.count)
        var newChildCount = [Int](repeating: 0, count: newRecords.count)
        for old in 0..<count where !removed[old] {
            let newIdx = oldToNew[old]
            newChildStart[newIdx] = newChildIndices.count
            let start = childStart[old]
            let cnt = childCount[old]
            var kept = 0
            for offsetI in 0..<cnt {
                let childOld = childIndices[start + offsetI]
                if childOld == index {
                    newChildIndices.append(offset + subtree.rootIndex)
                    kept += 1
                } else if !removed[childOld] {
                    newChildIndices.append(oldToNew[childOld])
                    kept += 1
                }
            }
            newChildCount[newIdx] = kept
        }
        // The subtree's own internal children spans, offset into the merged arrays.
        for i in 0..<subtree.records.count {
            let subStart = subtree.childStart[i]
            let subCnt = subtree.childCount[i]
            newChildStart[offset + i] = newChildIndices.count
            newChildCount[offset + i] = subCnt
            for offsetI in 0..<subCnt {
                newChildIndices.append(offset + subtree.childIndices[subStart + offsetI])
            }
        }

        // Re-sort only the spans whose child SIZES could actually have
        // changed order: the replaced node's new parent (its composition
        // changed — one child was swapped for another) and every ancestor
        // above it up to the root (same members, but one of them now has a
        // different size). Bounded by tree depth, not total node count —
        // everything else in the tree kept both its members and their sizes
        // untouched, so it's already still sorted.
        var ancestorNewIndices: [Int] = [oldToNew[oldParent]]
        var a = parentIndex[oldParent]
        while a >= 0 {
            ancestorNewIndices.append(oldToNew[a])
            a = parentIndex[a]
        }
        for newIdx in ancestorNewIndices {
            let start = newChildStart[newIdx]
            let cnt = newChildCount[newIdx]
            guard cnt > 1 else { continue }
            var slice = Array(newChildIndices[start..<(start + cnt)])
            slice.sort { newRecords[$0].size > newRecords[$1].size }
            newChildIndices.replaceSubrange(start..<(start + cnt), with: slice)
        }

        return FileTree(
            records: newRecords,
            parentIndex: newParentIndex,
            childStart: newChildStart,
            childCount: newChildCount,
            childIndices: newChildIndices,
            rootIndex: oldToNew[rootIndex],
            rootPath: rootPath
        )
    }
}
