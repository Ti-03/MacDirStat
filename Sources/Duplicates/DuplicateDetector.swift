import Foundation
import CryptoKit

public actor DuplicateDetector {
    private let minSize: Int64 = 4 * 1024            // skip files < 4 KB
    private let maxSize: Int64 = 512 * 1024 * 1024   // skip files > 512 MB (VM images, sparsebundles, etc.)
    private let quickHashBytes = 65_536              // 64 KB quick pre-filter

    // Bounded concurrency for I/O-bound hashing work.
    private static var maxConcurrency: Int {
        min(8, ProcessInfo.processInfo.activeProcessorCount)
    }

    public init() {}

    // Operates over flat FileTree indices rather than an FSNode tree — a
    // simple loop over `tree.records` reaches every node without recursion,
    // since the array already covers the whole tree regardless of hierarchy.
    public func detect(in tree: FileTree) async {
        var candidates: [Int] = []
        collect(tree: tree, into: &candidates)

        // Group by size first — eliminates the vast majority of files cheaply
        let bySize = Dictionary(grouping: candidates) { tree.records[$0].size }
            .filter { $0.value.count > 1 }

        let quickHashBytes = self.quickHashBytes

        // Phase 1: quick hash (first 64 KB) to rule out non-duplicates without reading entire files.
        // Hashing is I/O-bound and embarrassingly parallel, so run it with bounded concurrency.
        var byQuickHash: [String: [Int]] = [:]
        let quickHashResults: [(Int, String)]? = await Self.hashInParallel(
            indices: bySize.values.flatMap { $0 }
        ) { index in
            Self.partialHash(url: FileNode(tree: tree, index: index).url, maxBytes: quickHashBytes)
        }
        guard let quickHashResults else { return }
        for (index, qh) in quickHashResults {
            let key = "\(tree.records[index].size)-\(qh)"
            byQuickHash[key, default: []].append(index)
        }

        // Small-file shortcut: if a file's whole content fits within the quick-hash window,
        // the quick hash already IS a full-content hash, so those groups are final as-is.
        // Only groups whose files exceed the quick-hash window need a full-file hash pass.
        var hashGroups: [String: [Int]] = [:]
        var toFullHash: [Int] = []
        for (key, indices) in byQuickHash where indices.count > 1 {
            if tree.records[indices[0]].size <= Int64(quickHashBytes) {
                hashGroups[key] = indices
            } else {
                toFullHash.append(contentsOf: indices)
            }
        }

        // Phase 2: full hash only for groups that survived the quick-hash filter and are
        // larger than the quick-hash window (their quick hash alone is not conclusive).
        if !toFullHash.isEmpty {
            let fullHashResults: [(Int, String)]? = await Self.hashInParallel(indices: toFullHash) { index in
                Self.fullHash(url: FileNode(tree: tree, index: index).url)
            }
            guard let fullHashResults else { return }
            for (index, hash) in fullHashResults {
                let key = "\(tree.records[index].size)-\(hash)"
                hashGroups[key, default: []].append(index)
            }
        }

        // Assign group IDs to genuine duplicates
        for (_, indices) in hashGroups where indices.count > 1 {
            guard !Task.isCancelled else { return }
            let groupID = UUID()
            for index in indices { tree.setDuplicateGroupID(groupID, at: index) }
        }
    }

    private func collect(tree: FileTree, into list: inout [Int]) {
        for index in 0..<tree.records.count {
            let record = tree.records[index]
            // Synthetic nodes (e.g. the hidden-space reconciliation entry) have no
            // real file behind their URL — hashing them would just fail harmlessly,
            // but skip them outright rather than waste the attempt.
            if !record.isSynthetic && !record.isDirectory && record.size >= minSize && record.size <= maxSize {
                list.append(index)
            }
        }
    }

    // Runs `hash` over `indices` with bounded sliding-window concurrency, returning nil if the
    // task was cancelled before completion. Indices for which `hash` returns nil are dropped.
    private static func hashInParallel(
        indices: [Int],
        hash: @escaping @Sendable (Int) -> String?
    ) async -> [(Int, String)]? {
        guard !indices.isEmpty else { return [] }
        guard !Task.isCancelled else { return nil }

        var results: [(Int, String)] = []
        results.reserveCapacity(indices.count)

        await withTaskGroup(of: (Int, String?).self) { group in
            var cursor = 0
            let limit = maxConcurrency

            func launchNext() {
                guard cursor < indices.count else { return }
                let index = indices[cursor]
                cursor += 1
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, hash(index))
                }
            }

            // Prime the sliding window.
            while cursor < limit && cursor < indices.count {
                launchNext()
            }

            while let (index, key) = await group.next() {
                if let key {
                    results.append((index, key))
                }
                if Task.isCancelled {
                    // Drain remaining in-flight tasks without launching more.
                    continue
                }
                launchNext()
            }
        }

        guard !Task.isCancelled else { return nil }
        return results
    }

    // Reads up to `maxBytes` from the file and returns a SHA256 hex string.
    // Each chunk is drained from the autorelease pool immediately to prevent accumulation.
    private static func partialHash(url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = maxBytes
        let chunkSize = min(65_536, maxBytes)
        while remaining > 0 {
            if Task.isCancelled { return nil }
            let toRead = min(chunkSize, remaining)
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: toRead) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Full-file SHA256. Each 1 MB chunk is released immediately via autoreleasepool,
    // capping peak memory at ~1 MB regardless of file size.
    private static func fullHash(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            if Task.isCancelled { return nil }
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
