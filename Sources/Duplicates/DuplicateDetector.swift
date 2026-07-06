import Foundation
import CryptoKit

public actor DuplicateDetector {
    private let minSize: Int64 = 4 * 1024            // skip files < 4 KB
    private let maxSize: Int64 = 512 * 1024 * 1024   // skip files > 512 MB (VM images, sparsebundles, etc.)
    private let quickHashBytes = 65_536              // 64 KB quick pre-filter

    public init() {}

    public func detect(in root: FSNode) async {
        var candidates: [FSNode] = []
        collect(node: root, into: &candidates)

        // Group by size first — eliminates the vast majority of files cheaply
        let bySize = Dictionary(grouping: candidates) { $0.size }
            .filter { $0.value.count > 1 }

        // Phase 1: quick hash (first 64 KB) to rule out non-duplicates without reading entire files
        var byQuickHash: [String: [FSNode]] = [:]
        for (_, nodes) in bySize {
            for node in nodes {
                guard !Task.isCancelled else { return }
                if let qh = partialHash(url: node.url, maxBytes: quickHashBytes) {
                    let key = "\(node.size)-\(qh)"
                    byQuickHash[key, default: []].append(node)
                }
            }
        }

        // Phase 2: full hash only for groups that survived the quick-hash filter
        var hashGroups: [String: [FSNode]] = [:]
        for (_, nodes) in byQuickHash where nodes.count > 1 {
            for node in nodes {
                guard !Task.isCancelled else { return }
                if let hash = fullHash(url: node.url) {
                    let key = "\(node.size)-\(hash)"
                    hashGroups[key, default: []].append(node)
                }
            }
        }

        // Assign group IDs to genuine duplicates
        for (_, nodes) in hashGroups where nodes.count > 1 {
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

    // Reads up to `maxBytes` from the file and returns a SHA256 hex string.
    // Each chunk is drained from the autorelease pool immediately to prevent accumulation.
    private func partialHash(url: URL, maxBytes: Int) -> String? {
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
    private func fullHash(url: URL) -> String? {
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
