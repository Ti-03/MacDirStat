import Foundation

// Persists a completed `FileTree` to disk and reloads it later as a
// read-only snapshot ("Save and Reopen Results"). The flat store's arrays
// are trivially Codable (see the conformances added to `FileNodeRecord`,
// `HardLinkRef`, and `SafetyLevel`), so this is a thin envelope: the raw
// topology arrays plus a small metadata block describing where/when the
// scan happened.
//
// Format is plain JSON (not gzipped) behind a `.mdscan` extension —
// `formatVersion` is carried so a future revision (e.g. adding compression,
// or new per-node fields) can still read old archives or reject ones it
// doesn't understand.
public struct ScanArchive: Codable, Sendable {
    public static let currentFormatVersion = 1

    public struct Metadata: Codable, Sendable {
        public let scannedPath: String
        public let scanDate: Date
        public let deniedCount: Int
        public let appVersion: String
        public let formatVersion: Int

        public init(scannedPath: String, scanDate: Date, deniedCount: Int, appVersion: String, formatVersion: Int = ScanArchive.currentFormatVersion) {
            self.scannedPath = scannedPath
            self.scanDate = scanDate
            self.deniedCount = deniedCount
            self.appVersion = appVersion
            self.formatVersion = formatVersion
        }
    }

    public let records: [FileNodeRecord]
    public let parentIndex: [Int]
    public let childStart: [Int]
    public let childCount: [Int]
    public let childIndices: [Int]
    public let rootIndex: Int
    public let rootPath: String
    public let metadata: Metadata

    public init(tree: FileTree, metadata: Metadata) {
        self.records = tree.records
        self.parentIndex = tree.parentIndex
        self.childStart = tree.childStart
        self.childCount = tree.childCount
        self.childIndices = tree.childIndices
        self.rootIndex = tree.rootIndex
        self.rootPath = tree.rootPath
        self.metadata = metadata
    }

    // Rebuilds a live `FileTree` from the archived arrays. Callers MUST run
    // `validate()` first — this initializer trusts the topology is sound.
    public func makeTree() -> FileTree {
        FileTree(
            records: records,
            parentIndex: parentIndex,
            childStart: childStart,
            childCount: childCount,
            childIndices: childIndices,
            rootIndex: rootIndex,
            rootPath: rootPath
        )
    }

    // MARK: - Validation

    // A hostile or corrupted archive must never crash the app or hang it —
    // every check here is a bounds/consistency check performed with plain
    // array indexing, and the whole-tree walk is iterative (explicit stack)
    // and visits each node at most once, so it terminates even if the
    // topology is cyclic.
    public func validate() throws {
        let count = records.count

        guard count > 0 else { throw ScanArchiveError.corrupted("Archive contains no records") }
        // A generous upper bound: guards against a maliciously/corruptly
        // huge archive trying to exhaust memory, while never limiting any
        // real scan (tens of millions of files is already far beyond what
        // this app scans in practice).
        guard count <= 50_000_000 else { throw ScanArchiveError.corrupted("Archive is implausibly large (\(count) records)") }

        guard parentIndex.count == count, childStart.count == count, childCount.count == count else {
            throw ScanArchiveError.corrupted("Archive arrays have mismatched lengths")
        }

        guard rootIndex >= 0, rootIndex < count else {
            throw ScanArchiveError.corrupted("Root index out of range")
        }
        guard parentIndex[rootIndex] < 0 else {
            throw ScanArchiveError.corrupted("Root node has a parent")
        }

        // Every child span must be in range before touching childIndices.
        var totalSpanned = 0
        for i in 0..<count {
            let start = childStart[i]
            let cnt = childCount[i]
            guard cnt >= 0, start >= 0 else {
                throw ScanArchiveError.corrupted("Negative child span at index \(i)")
            }
            guard start + cnt <= childIndices.count else {
                throw ScanArchiveError.corrupted("Child span out of range at index \(i)")
            }
            totalSpanned += cnt
        }
        guard totalSpanned == childIndices.count else {
            throw ScanArchiveError.corrupted("Child spans don't cover childIndices exactly")
        }

        // Every entry in childIndices must reference a valid, non-self node,
        // and must agree with that child's own parentIndex.
        for i in 0..<count {
            let start = childStart[i]
            let cnt = childCount[i]
            for offset in 0..<cnt {
                let child = childIndices[start + offset]
                guard child >= 0, child < count else {
                    throw ScanArchiveError.corrupted("Child index out of range under parent \(i)")
                }
                guard child != i else {
                    throw ScanArchiveError.corrupted("Node \(i) lists itself as its own child")
                }
                guard parentIndex[child] == i else {
                    throw ScanArchiveError.corrupted("parentIndex/childIndices disagree for node \(child)")
                }
            }
        }

        // Whole-tree reachability walk from root, iterative so a cycle can't
        // hang the app — a node already marked visited is simply skipped
        // rather than re-pushed, and if a cycle exists among unreached
        // nodes, they just never get visited and the final count check
        // below catches it.
        var visited = [Bool](repeating: false, count: count)
        var stack = [rootIndex]
        var visitedCount = 0
        while let i = stack.popLast() {
            if visited[i] { continue }
            visited[i] = true
            visitedCount += 1
            let start = childStart[i]
            let cnt = childCount[i]
            for offset in 0..<cnt {
                let child = childIndices[start + offset]
                if !visited[child] { stack.append(child) }
            }
        }
        guard visitedCount == count else {
            throw ScanArchiveError.corrupted("Archive contains unreachable nodes or a parent cycle")
        }
    }
}

public enum ScanArchiveError: Error, LocalizedError, Equatable {
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let reason):
            return "This scan file is damaged or invalid (\(reason))."
        }
    }
}
