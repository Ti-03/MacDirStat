import Foundation

// Converts a scanner-internal `FSNode` class tree into a flat `FileTree`.
// `FSNode` remains the scanner's own build type (see FileScanner.swift) so
// none of the traversal logic there had to change; this is the one place
// that walks an already-fully-built `FSNode` tree and assembles the
// compact, app-facing store from it.
//
// Public so tests (and, in principle, any future consumer that still builds
// an `FSNode` tree by hand — e.g. the live-refresh rescan helpers) can drive
// the rest of the app's data flow (layout, view model, duplicate detection)
// from a small hand-built fixture without going through a real disk scan.
public enum FileTreeBuilder {
    public static func build(from root: FSNode, rootPath: String) -> FileTree {
        var records: [FileNodeRecord] = []
        var parentIndex: [Int] = []
        // Children discovered so far for each index, built up as nodes are
        // visited; flattened into `childIndices`/`childStart`/`childCount`
        // once the full traversal is done.
        var childrenOf: [[Int]] = []

        // Iterative pre-order walk (explicit stack, not recursion) so
        // assembly can't stack-overflow on a very deep real-world tree —
        // mirrors the style of the scanner's own iterative traversal.
        //
        // Children are pushed in ascending-size order so the stack (LIFO)
        // pops them back off in descending-size order; since a child is
        // appended to its parent's `childrenOf` entry at the moment it's
        // popped, this guarantees `childrenOf[i]` ends up sorted size-desc —
        // the invariant `FileNode.children` promises its callers.
        var stack: [(node: FSNode, parent: Int)] = [(root, -1)]
        while let (node, parent) = stack.popLast() {
            let index = records.count
            records.append(FileNodeRecord(
                name: node.name,
                isDirectory: node.isDirectory,
                size: node.size,
                fileExtension: node.fileExtension,
                isAccessDenied: node.isAccessDenied,
                isSynthetic: node.isSynthetic,
                isAutoSummarized: node.isAutoSummarized,
                descendantFileCount: node.descendantFileCount,
                hardLinkRef: node.hardLinkRef,
                // Filled post-assembly: safety tagging and duplicate
                // detection both run as a pass over the finished FileTree.
                duplicateGroupID: nil,
                safetyLevel: .caution
            ))
            parentIndex.append(parent)
            childrenOf.append([])
            if parent >= 0 {
                childrenOf[parent].append(index)
            }

            let sortedChildren = node.children.sorted { $0.size > $1.size }
            for child in sortedChildren.reversed() {
                stack.append((child, index))
            }
        }

        var childIndices: [Int] = []
        childIndices.reserveCapacity(records.count)
        var childStart = [Int](repeating: 0, count: records.count)
        var childCount = [Int](repeating: 0, count: records.count)
        for i in 0..<records.count {
            childStart[i] = childIndices.count
            childCount[i] = childrenOf[i].count
            childIndices.append(contentsOf: childrenOf[i])
        }

        return FileTree(
            records: records,
            parentIndex: parentIndex,
            childStart: childStart,
            childCount: childCount,
            childIndices: childIndices,
            rootIndex: 0,
            rootPath: rootPath
        )
    }
}
