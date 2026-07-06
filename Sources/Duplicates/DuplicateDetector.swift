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

    public func detect(in root: FSNode) async {
        var candidates: [FSNode] = []
        collect(node: root, into: &candidates)

        // Group by size first — eliminates the vast majority of files cheaply
        let bySize = Dictionary(grouping: candidates) { $0.size }
            .filter { $0.value.count > 1 }

        let quickHashBytes = self.quickHashBytes

        // Phase 1: quick hash (first 64 KB) to rule out non-duplicates without reading entire files.
        // Hashing is I/O-bound and embarrassingly parallel, so run it with bounded concurrency.
        var byQuickHash: [String: [FSNode]] = [:]
        let quickHashResults: [(FSNode, String)]? = await Self.hashInParallel(
            nodes: bySize.values.flatMap { $0 }
        ) { node in
            Self.partialHash(url: node.url, maxBytes: quickHashBytes)
        }
        guard let quickHashResults else { return }
        for (node, qh) in quickHashResults {
            let key = "\(node.size)-\(qh)"
            byQuickHash[key, default: []].append(node)
        }

        // Small-file shortcut: if a file's whole content fits within the quick-hash window,
        // the quick hash already IS a full-content hash, so those groups are final as-is.
        // Only groups whose files exceed the quick-hash window need a full-file hash pass.
        var hashGroups: [String: [FSNode]] = [:]
        var toFullHash: [FSNode] = []
        for (key, nodes) in byQuickHash where nodes.count > 1 {
            if nodes[0].size <= Int64(quickHashBytes) {
                hashGroups[key] = nodes
            } else {
                toFullHash.append(contentsOf: nodes)
            }
        }

        // Phase 2: full hash only for groups that survived the quick-hash filter and are
        // larger than the quick-hash window (their quick hash alone is not conclusive).
        if !toFullHash.isEmpty {
            let fullHashResults: [(FSNode, String)]? = await Self.hashInParallel(nodes: toFullHash) { node in
                Self.fullHash(url: node.url)
            }
            guard let fullHashResults else { return }
            for (node, hash) in fullHashResults {
                let key = "\(node.size)-\(hash)"
                hashGroups[key, default: []].append(node)
            }
        }

        // Assign group IDs to genuine duplicates
        for (_, nodes) in hashGroups where nodes.count > 1 {
            guard !Task.isCancelled else { return }
            let groupID = UUID()
            for node in nodes { node.duplicateGroupID = groupID }
        }
    }

    private func collect(node: FSNode, into list: inout [FSNode]) {
        var stack: [FSNode] = [node]
        while let current = stack.popLast() {
            // Synthetic nodes (e.g. the hidden-space reconciliation entry) have no
            // real file behind their URL — hashing them would just fail harmlessly,
            // but skip them outright rather than waste the attempt.
            if !current.isSynthetic && !current.isDirectory && current.size >= minSize && current.size <= maxSize {
                list.append(current)
            }
            stack.append(contentsOf: current.children)
        }
    }

    // Runs `hash` over `nodes` with bounded sliding-window concurrency, returning nil if the
    // task was cancelled before completion. Nodes for which `hash` returns nil are dropped.
    private static func hashInParallel(
        nodes: [FSNode],
        hash: @escaping @Sendable (FSNode) -> String?
    ) async -> [(FSNode, String)]? {
        guard !nodes.isEmpty else { return [] }
        guard !Task.isCancelled else { return nil }

        var results: [(FSNode, String)] = []
        results.reserveCapacity(nodes.count)

        await withTaskGroup(of: (FSNode, String?).self) { group in
            var index = 0
            let limit = maxConcurrency

            func launchNext() {
                guard index < nodes.count else { return }
                let node = nodes[index]
                index += 1
                group.addTask {
                    guard !Task.isCancelled else { return (node, nil) }
                    return (node, hash(node))
                }
            }

            // Prime the sliding window.
            while index < limit && index < nodes.count {
                launchNext()
            }

            while let (node, key) = await group.next() {
                if let key {
                    results.append((node, key))
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
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
