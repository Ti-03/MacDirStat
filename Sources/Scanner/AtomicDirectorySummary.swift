import Darwin
import Dispatch
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
// immediate-file-count/average-size heuristic. Phase 3.5 replaced the walk
// itself with a bounded parallel pool (see `summarizeSubtree` below) so that
// summarizing a huge subtree is a scan-speed win too, not just a node-count
// win.

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
    // for the pattern; out of scope here to keep the summarization gate simple.
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

// Thread-safe pending-directory queue for the summarization walk, analogous
// to `WorkQueue` in FileScanner.swift but holding directory PATHS (a
// directory's (dev, ino) dedup check already happened when it was
// discovered and pushed here, so the queue itself needs no identity checks).
// `pop()` returning nil doesn't mean "done" - callers must also check
// `isFinished` (stack empty AND nothing in flight), since another worker's
// current item may still push more work.
private final class SummaryDirQueue: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var stack: [String]
    private var inFlight: Int

    init(seed: [String]) {
        stack = seed
        inFlight = seed.count
    }

    func push(_ path: String) {
        os_unfair_lock_lock(&lock)
        stack.append(path)
        inFlight += 1
        os_unfair_lock_unlock(&lock)
    }

    func pop() -> String? {
        os_unfair_lock_lock(&lock)
        let item = stack.popLast()
        os_unfair_lock_unlock(&lock)
        return item
    }

    // Call exactly once per path that was popped, after it has been fully
    // processed (including pushing any subdirectories it discovered).
    func markDone() {
        os_unfair_lock_lock(&lock)
        inFlight -= 1
        os_unfair_lock_unlock(&lock)
    }

    var isFinished: Bool {
        os_unfair_lock_lock(&lock)
        let finished = stack.isEmpty && inFlight == 0
        os_unfair_lock_unlock(&lock)
        return finished
    }
}

// Thread-safe running total for the summarization walk's aggregate result.
private final class SummaryAccumulator: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var totalAllocated: Int64
    private var totalFileCount: Int

    init(allocatedSize: Int64, fileCount: Int) {
        totalAllocated = allocatedSize
        totalFileCount = fileCount
    }

    func add(files: Int, bytes: Int64) {
        os_unfair_lock_lock(&lock)
        totalAllocated += bytes
        totalFileCount += files
        os_unfair_lock_unlock(&lock)
    }

    var snapshot: (allocatedSize: Int64, fileCount: Int) {
        os_unfair_lock_lock(&lock)
        let result = (totalAllocated, totalFileCount)
        os_unfair_lock_unlock(&lock)
        return result
    }
}

// Tiny lock-guarded box used only to carry the first error thrown by the
// worker pool back across the sync/async bridge in `summarizeSubtree`.
private final class SummaryResultBox: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var storedError: Error?

    func setErrorIfAbsent(_ error: Error) {
        os_unfair_lock_lock(&lock)
        if storedError == nil { storedError = error }
        os_unfair_lock_unlock(&lock)
    }

    var error: Error? {
        os_unfair_lock_lock(&lock)
        let result = storedError
        os_unfair_lock_unlock(&lock)
        return result
    }
}

// Parallel walk of the subtree rooted at a directory already deemed a
// summarization candidate. Applies the exact same scan semantics as the main
// traversal (symlink/hidden/exclusion/mount-point skips, hardlink +
// directory dedup via the shared `visited` set) so the aggregate size/file
// count it returns matches what a full, non-summarized scan of the same
// subtree would have produced - regardless of how many workers race to
// discover each directory/file, since `visited.visit` is atomic. That
// invariant (count each (dev, ino) exactly once, no matter which worker sees
// it first) is exactly why this parallel result equals the single-threaded
// result computed before Phase 3.5.
//
// `rootEntries` is the already-decoded listing of the candidate directory
// itself (the caller enumerated it once to run `shouldAutoSummarize`); reused
// here instead of re-enumerating so summarization costs zero extra I/O for
// the root of the collapsed subtree. That root listing is consumed
// synchronously, on the calling thread, exactly as before Phase 3.5 - only
// once there is more than one discovered subdirectory do we spin up the
// worker pool below.
//
// No FSNode objects are built here, so there is no shared-mutable-node
// hazard to worry about; the only shared mutable state is the queue and the
// accumulator, both lock-guarded.
//
// Concurrency bridge: this function's signature stays synchronous (`throws`,
// not `async`) so its one call site in FileScanner.swift is unchanged - it
// already runs on one of the main scan's worker threads, itself inside an
// async Task. To drive `withThrowingTaskGroup` from here, it hands the pool
// off to a detached Task and blocks this thread on a semaphore, polling with
// a short timeout so it can keep re-checking the ORIGINAL caller's
// cancellation via the passed-in `cancel` closure (`Task.checkCancellation`
// is dynamic-scoped to whatever Task is executing at the call site, so
// checking it here - still on the calling worker's own Task - reflects the
// real scan's cancellation; the detached pool Task is a separate Task, so
// checking cancellation from inside it would never see the outer scan being
// cancelled unless we explicitly forward it, which is what the polling loop
// below does via `poolTask.cancel()`).
//
// This runs nested inside one main-scan worker's task; a nested worker pool
// is fine here. Oversubscription (main pool x summary pool) is bounded (both
// pools cap at 8 workers) and self-limiting: only directories big enough to
// trip auto-summarization spin up a nested pool at all, and macOS's
// thread-pool scheduling handles the resulting oversubscription gracefully.
func summarizeSubtree(
    rootEntries: [BulkDirEntry],
    rootPath: String,
    rootDev: UInt64,
    config: ScanConfig,
    visited: VisitedSet,
    cancel: @Sendable @escaping () throws -> Void
) throws -> (allocatedSize: Int64, fileCount: Int) {
    var totalAllocated: Int64 = 0
    var fileCount = 0
    var seedDirs: [String] = []
    var entriesSeen = 0

    for entry in rootEntries {
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
            let childPath = rootPath.hasSuffix("/") ? rootPath + entry.name : rootPath + "/" + entry.name
            seedDirs.append(childPath)

        case .file:
            totalAllocated += bulkAllocatedSize(entry: entry, visited: visited)
            fileCount += 1
        }
    }

    // No subdirectories discovered at the candidate root: nothing left to
    // walk, so skip spinning up a worker pool entirely.
    guard !seedDirs.isEmpty else {
        return (totalAllocated, fileCount)
    }

    let queue = SummaryDirQueue(seed: seedDirs)
    let accumulator = SummaryAccumulator(allocatedSize: totalAllocated, fileCount: fileCount)
    let resultBox = SummaryResultBox()
    let workerCount = min(max(2, ProcessInfo.processInfo.activeProcessorCount / 2), 8)

    let semaphore = DispatchSemaphore(value: 0)
    let poolTask = Task.detached(priority: .userInitiated) {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        try await _summaryWorker(queue: queue, rootDev: rootDev, config: config, visited: visited, accumulator: accumulator, cancel: cancel)
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            resultBox.setErrorIfAbsent(error)
        }
        semaphore.signal()
    }

    while semaphore.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
        if (try? cancel()) == nil {
            poolTask.cancel()
        }
    }

    if let error = resultBox.error { throw error }

    let final = accumulator.snapshot
    return (final.allocatedSize, final.fileCount)
}

private func _summaryWorker(
    queue: SummaryDirQueue,
    rootDev: UInt64,
    config: ScanConfig,
    visited: VisitedSet,
    accumulator: SummaryAccumulator,
    cancel: @Sendable () throws -> Void
) async throws {
    while true {
        try cancel()
        if let dirPath = queue.pop() {
            try _processSummaryDirectory(dirPath: dirPath, rootDev: rootDev, config: config, visited: visited, accumulator: accumulator, queue: queue, cancel: cancel)
            continue
        }
        if queue.isFinished { return }
        await Task.yield()
    }
}

// Processes exactly one directory of the summarized subtree: opens it, lists
// its immediate children (bulk enumeration with fallback), applies all scan
// semantics, adds direct file bytes/count to the shared accumulator, and
// pushes any subdirectories as new queue entries. Always calls
// `queue.markDone()` exactly once, even on early return - mirrors
// `_processDirectory` in FileScanner.swift.
private func _processSummaryDirectory(
    dirPath: String,
    rootDev: UInt64,
    config: ScanConfig,
    visited: VisitedSet,
    accumulator: SummaryAccumulator,
    queue: SummaryDirQueue,
    cancel: @Sendable () throws -> Void
) throws {
    defer { queue.markDone() }
    try cancel()

    let fd = open(dirPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return }
    defer { close(fd) }

    let entries: [BulkDirEntry]
    do {
        entries = try listDirectoryEntries(path: dirPath, fd: fd, forceFallback: config.forceFallbackEnum)
    } catch {
        // Enumeration failed even after falling back: contributes nothing
        // further, matches the main scanner's "treat as empty" rule.
        return
    }

    var entriesSeen = 0
    var localFiles = 0
    var localBytes: Int64 = 0

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
            queue.push(childPath)

        case .file:
            localBytes += bulkAllocatedSize(entry: entry, visited: visited)
            localFiles += 1
        }
    }

    // Batch this directory's file bytes/count into a single lock acquisition
    // rather than one per file.
    if localFiles > 0 { accumulator.add(files: localFiles, bytes: localBytes) }
}
