import Foundation

// A single reported difference between two scans of (nominally) the same
// root, keyed by the node's path relative to that root so it's meaningful
// even when `before`/`after` are two entirely separate `FileTree` instances
// (e.g. one loaded from a `.mdscan` archive, one the live in-memory scan).
public struct ScanChange: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case added
        case removed
        case grew
        case shrank
        // Same path, different kind of thing: a file was replaced by a
        // directory or vice versa. Reported as its own row because neither
        // "added"/"removed" (the path exists on both sides) nor
        // "grew"/"shrank" (which compare like with like) describes it.
        case replaced
    }

    public let relativePath: String
    public let name: String
    public let isDirectory: Bool
    public let kind: Kind
    public let beforeSize: Int64
    public let afterSize: Int64

    public var delta: Int64 { afterSize - beforeSize }
    public var id: String { relativePath }

    public init(relativePath: String, name: String, isDirectory: Bool, kind: Kind, beforeSize: Int64, afterSize: Int64) {
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind
        self.beforeSize = beforeSize
        self.afterSize = afterSize
    }
}

// Diffs two `FileTree`s ("Compare Scans Over Time"): what was added, removed,
// grew, or shrank between them. Read-only — never mutates either tree.
public enum ScanComparison {
    // Builds an index of every node in `tree`, keyed by its path relative to
    // `tree.rootPath` (root itself is the empty string), and diffs the two
    // resulting maps. Each tree is indexed exactly once via a single
    // iterative DFS (see `relativePathIndex`), so the whole comparison is
    // O(nBefore + nAfter) — no nested tree-against-tree scanning — which
    // keeps it cheap even on multi-million-node trees.
    public static func compare(before: FileTree, after: FileTree) -> [ScanChange] {
        let beforeIndex = relativePathIndex(of: before)
        let afterIndex = relativePathIndex(of: after)

        var changes: [ScanChange] = []

        // Added: present in `after`, absent from `before`. Collapsed to the
        // topmost new node in each new subtree — a node is only reported if
        // its parent already existed in `before` (i.e. the parent is NOT
        // itself newly added); every descendant of a newly-added directory
        // is skipped here, since it's implied by the directory's own
        // "added" row, exactly like Radix's diff-row suppression.
        for (relativePath, afterNodeIndex) in afterIndex {
            guard beforeIndex[relativePath] == nil else { continue }
            // The parent counts as pre-existing only if it was there AND was
            // already a directory. If it was a *file* that has since become a
            // directory, everything now inside it is new content implied by
            // that node's own "replaced" row, so suppress it here.
            if let parentPath = parentRelativePath(of: relativePath),
               !existsAsDirectory(parentPath, in: beforeIndex, of: before) {
                continue
            }
            let record = after.records[afterNodeIndex]
            changes.append(ScanChange(
                relativePath: relativePath,
                name: record.name,
                isDirectory: record.isDirectory,
                kind: .added,
                beforeSize: 0,
                afterSize: record.size
            ))
        }

        // Removed: present in `before`, absent from `after`. Same collapsing
        // rule, mirrored: skip a node whose parent is also removed (not
        // present in `after`) — only the topmost removed node per subtree is
        // reported.
        for (relativePath, beforeNodeIndex) in beforeIndex {
            guard afterIndex[relativePath] == nil else { continue }
            // Mirror of the added-side rule: if the parent is now a file where
            // it used to be a directory, this node's disappearance is implied
            // by the parent's "replaced" row.
            if let parentPath = parentRelativePath(of: relativePath),
               !existsAsDirectory(parentPath, in: afterIndex, of: after) {
                continue
            }
            let record = before.records[beforeNodeIndex]
            changes.append(ScanChange(
                relativePath: relativePath,
                name: record.name,
                isDirectory: record.isDirectory,
                kind: .removed,
                beforeSize: record.size,
                afterSize: 0
            ))
        }

        // Grew/shrank: only for *files* present in both trees whose size
        // differs. Directories present in both are deliberately never
        // reported here — a directory's size is entirely derived from its
        // descendants, so any real change under it already surfaces as an
        // added/removed/grew/shrank row for that descendant; reporting the
        // containing directories too would just be noisy duplication of the
        // same information at every level of the path.
        for (relativePath, beforeNodeIndex) in beforeIndex {
            guard let afterNodeIndex = afterIndex[relativePath] else { continue }
            let beforeRecord = before.records[beforeNodeIndex]
            let afterRecord = after.records[afterNodeIndex]

            // Type change (file <-> directory) at the same path. Reported
            // regardless of whether the size happens to match, since the node
            // is fundamentally a different thing now — and without this the
            // pair would fall through both guards below and vanish from the
            // report entirely.
            if beforeRecord.isDirectory != afterRecord.isDirectory {
                changes.append(ScanChange(
                    relativePath: relativePath,
                    name: afterRecord.name,
                    isDirectory: afterRecord.isDirectory,
                    kind: .replaced,
                    beforeSize: beforeRecord.size,
                    afterSize: afterRecord.size
                ))
                continue
            }

            guard !beforeRecord.isDirectory, !afterRecord.isDirectory else { continue }
            guard beforeRecord.size != afterRecord.size else { continue }
            changes.append(ScanChange(
                relativePath: relativePath,
                name: afterRecord.name,
                isDirectory: false,
                kind: afterRecord.size > beforeRecord.size ? .grew : .shrank,
                beforeSize: beforeRecord.size,
                afterSize: afterRecord.size
            ))
        }

        return changes.sorted { abs($0.delta) > abs($1.delta) }
    }

    // Iterative DFS (explicit stack, mirroring `FileTree.removingSubtrees`'s
    // style) building every node's root-relative path incrementally from its
    // parent's — O(n) total, unlike calling `FileTree.path(of:)` per node
    // (which walks the parent chain from scratch each time and would be
    // O(n·depth) over a whole tree).
    private static func relativePathIndex(of tree: FileTree) -> [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(tree.records.count)

        var stack: [(index: Int, relativePath: String)] = [(tree.rootIndex, "")]
        while let (nodeIndex, relativePath) = stack.popLast() {
            index[relativePath] = nodeIndex
            let start = tree.childStart[nodeIndex]
            let count = tree.childCount[nodeIndex]
            for offset in 0..<count {
                let childIndex = tree.childIndices[start + offset]
                let childName = tree.records[childIndex].name
                let childRelativePath = relativePath.isEmpty ? childName : relativePath + "/" + childName
                stack.append((childIndex, childRelativePath))
            }
        }
        return index
    }

    // The empty string denotes the root itself, which has no parent to
    // report against — `nil` in that case, so callers never try to collapse
    // the root away.
    private static func parentRelativePath(of relativePath: String) -> String? {
        guard let lastSlash = relativePath.lastIndex(of: "/") else {
            return relativePath.isEmpty ? nil : ""
        }
        return String(relativePath[..<lastSlash])
    }

    // Whether `relativePath` existed in the given tree AND was a directory
    // there. Used by the add/remove collapsing rules: a path that existed only
    // as a *file* is not a container its children could have "already been
    // inside", so those children must be suppressed in favour of the parent's
    // own `.replaced` row.
    private static func existsAsDirectory(
        _ relativePath: String,
        in index: [String: Int],
        of tree: FileTree
    ) -> Bool {
        guard let nodeIndex = index[relativePath] else { return false }
        return tree.records[nodeIndex].isDirectory
    }
}
