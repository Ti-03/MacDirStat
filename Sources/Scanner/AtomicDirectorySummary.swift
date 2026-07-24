import Darwin
import Foundation

// Auto-summarization: when a directory is clearly a generated / tiny-file
// tree (node_modules, huge flat caches, ...), the scanner collapses its
// entire subtree into ONE leaf FSNode carrying the deep allocated size and a
// descendant file count, instead of materializing an FSNode per descendant.
// This is the biggest remaining scan-speed/node-count win: no FSNode
// allocation, no tree-building overhead for a subtree the user never wants
// to browse file-by-file.
//
// v1 scope is deliberately simple: a named-layout shortcut plus an
// immediate-file-count/average-size heuristic, walked single-threaded by the
// one worker that already owns the candidate directory. See the TODOs below
// for what a later phase could add.

// Directory names that are, by convention, generated dependency/package
// trees not worth browsing file-by-file. Matched against a directory's own
// name; bypasses the depth gate below.
private let knownGeneratedDirectoryNames: Set<String> = ["node_modules"]

enum AtomicSummaryThresholds {
    // Overridable via env var so tests can exercise the general heuristic
    // without creating thousands of real files.
    static var minFileCount: Int {
        if let raw = ProcessInfo.processInfo.environment["MDS_SUMMARY_MIN_FILES"], let value = Int(raw) {
            return value
        }
        return 5_000
    }
    static let maxAverageFileSize: Int64 = 4_096
    static let minDepth = 2
}

// Cheap, allocation-free gate: decides whether `item`'s directory (already
// enumerated into `entries`, no extra I/O) should be collapsed into a single
// summarized FSNode instead of being expanded normally.
func shouldAutoSummarize(entries: [BulkDirEntry], name: String, depth: Int) -> Bool {
    // 1. Named-layout shortcut: known generated trees (e.g. node_modules)
    // often keep few files at their own top level (most live several levels
    // deep, e.g. node_modules/<pkg>/dist/...), so the immediate-file
    // heuristic below would miss them. Name match alone is enough for v1.
    if knownGeneratedDirectoryNames.contains(name), depth >= 1 {
        return true
    }

    // 2. General heuristic: lots of small immediate files, deep enough in
    // the tree that summarizing won't collapse something the user is
    // directly looking at.
    // TODO(phase3+): bounded descendant probe for ambiguous dirs (e.g. a
    // directory whose files are deeper than its immediate listing, but that
    // doesn't match a known name) - see Radix's AtomicDirectorySummarizer
    // for the pattern; out of scope here to keep the summary walk simple
    // and single-threaded.
    guard depth >= AtomicSummaryThresholds.minDepth else { return false }

    var fileCount = 0
    var totalAllocated: Int64 = 0
    for entry in entries where entry.kind == .file {
        fileCount += 1
        totalAllocated += entry.allocatedSize
    }
    guard fileCount > 0, fileCount >= AtomicSummaryThresholds.minFileCount else { return false }
    let averageAllocated = totalAllocated / Int64(fileCount)
    return averageAllocated < AtomicSummaryThresholds.maxAverageFileSize
}

// Iterative, single-threaded walk of the subtree rooted at a directory
// already deemed a summarization candidate. Applies the exact same scan
// semantics as the main traversal (symlink/hidden/exclusion/mount-point
// skips, hardlink + directory dedup via the shared `visited` set) so the
// aggregate size/file-count it returns matches what a full, non-summarized
// scan of the same subtree would have produced.
//
// `rootEntries` is the already-decoded listing of the candidate directory
// itself (the caller enumerated it once to run `shouldAutoSummarize`); reused
// here instead of re-enumerating so summarization costs zero extra I/O for
// the root of the collapsed subtree. Descendant directories are opened by
// path as the walk descends (this candidate directory is already being
// processed by one worker, so keeping the walk single-threaded here adds no
// contention - see TODO below for a future parallel version).
//
// TODO(phase3+): parallel summary pool - fan the descendant walk of very
// large summarized subtrees out across multiple workers, the way the main
// traversal does. Left single-threaded for v1: correctness and the
// node-count/scan-time win both come from not materializing FSNodes, which
// a single-threaded walk already delivers.
func summarizeSubtree(
    rootEntries: [BulkDirEntry],
    rootPath: String,
    rootDev: UInt64,
    config: ScanConfig,
    visited: VisitedSet,
    cancel: () throws -> Void
) throws -> (allocatedSize: Int64, fileCount: Int) {
    var totalAllocated: Int64 = 0
    var fileCount = 0
    var entriesSeen = 0

    // Directories still to be listed, identified by their full path (their
    // (dev, ino) dedup check already happened when they were discovered and
    // pushed here).
    var pendingDirs: [String] = []

    func consume(_ entries: [BulkDirEntry], dirPath: String) throws {
        for entry in entries {
            entriesSeen += 1
            if entriesSeen % 256 == 0 { try cancel() }

            guard entry.name != "." && entry.name != ".." else { continue }
            if entry.name.hasPrefix("."), !config.showHiddenFiles { continue }
            if config.excludedNames.contains(entry.name) { continue }

            switch entry.kind {
            case .symlink, .other:
                continue

            case .directory:
                // Mount point: skip directories on a different device than the scan root.
                if entry.dev != rootDev { continue }
                // Dedup by (dev, ino): same firmlink/hardlink protection as the main scanner.
                guard visited.visit(dev: entry.dev, ino: entry.ino) else { continue }
                let childPath = dirPath.hasSuffix("/") ? dirPath + entry.name : dirPath + "/" + entry.name
                pendingDirs.append(childPath)

            case .file:
                totalAllocated += bulkAllocatedSize(entry: entry, visited: visited)
                fileCount += 1
            }
        }
    }

    try consume(rootEntries, dirPath: rootPath)

    while let dirPath = pendingDirs.popLast() {
        try cancel()
        let fd = open(dirPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { continue }
        defer { close(fd) }

        let entries: [BulkDirEntry]
        do {
            entries = try listDirectoryEntries(path: dirPath, fd: fd, forceFallback: config.forceFallbackEnum)
        } catch {
            // Enumeration failed even after falling back: contributes
            // nothing further, matches the main scanner's "treat as empty" rule.
            continue
        }
        try consume(entries, dirPath: dirPath)
    }

    return (totalAllocated, fileCount)
}
