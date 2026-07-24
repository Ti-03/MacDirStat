import Foundation

// Thread-safe set tracking visited (dev, ino) pairs to prevent double-counting.
// On macOS, /System/Volumes/Data/Applications shares the same inode as /Applications, etc.
// Shared by both directory dedup (firmlinks/mount aliases) and hardlinked-file
// dedup: a directory's inode and a file's inode never collide on one device,
// so the two uses safely share one (dev, ino) namespace, exactly as before.
private final class VisitedSet: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var set = Set<DevIno>()

    private struct DevIno: Hashable {
        let dev: UInt64
        let ino: UInt64
    }

    // Returns true if this (dev, ino) was NOT previously seen (and marks it seen).
    func visit(dev: UInt64, ino: UInt64) -> Bool {
        let key = DevIno(dev: dev, ino: ino)
        os_unfair_lock_lock(&lock)
        let inserted = set.insert(key).inserted
        os_unfair_lock_unlock(&lock)
        return inserted
    }
}

// Thread-safe progress counter using os_unfair_lock
private final class ProgressCounter: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private(set) var items: Int = 0
    private(set) var bytes: Int64 = 0
    private(set) var denied: Int = 0

    func add(items: Int, bytes: Int64) {
        os_unfair_lock_lock(&lock)
        self.items += items
        self.bytes += bytes
        os_unfair_lock_unlock(&lock)
    }

    func addDenied() {
        os_unfair_lock_lock(&lock)
        self.denied += 1
        os_unfair_lock_unlock(&lock)
    }

    var snapshot: (items: Int, bytes: Int64) {
        os_unfair_lock_lock(&lock)
        let result = (items, bytes)
        os_unfair_lock_unlock(&lock)
        return result
    }

    var deniedCount: Int {
        os_unfair_lock_lock(&lock)
        let result = denied
        os_unfair_lock_unlock(&lock)
        return result
    }
}

// Snapshot of scan-time settings, read once per scan (not per directory) to avoid
// UserDefaults / environment overhead on the hot path.
struct ScanConfig: Sendable {
    let excludedNames: Set<String>
    let showHiddenFiles: Bool
    // Forces the readdir+fstatat fallback path for every directory in the scan,
    // bypassing getattrlistbulk entirely. Used by parity tests to compare the
    // two enumeration strategies against each other.
    let forceFallbackEnum: Bool

    static func loadFromUserDefaults() -> ScanConfig {
        let rawExcluded = UserDefaults.standard.string(forKey: "excludedFolderNames")
            ?? ".git,node_modules,DerivedData,.Trash"
        let excludedNames = Set(rawExcluded.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let showHiddenFiles = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        let forceFallbackEnum = ProcessInfo.processInfo.environment["MDS_FORCE_FALLBACK_ENUM"] == "1"
        return ScanConfig(excludedNames: excludedNames, showHiddenFiles: showHiddenFiles, forceFallbackEnum: forceFallbackEnum)
    }
}

public actor FileScanner {
    private var activeTask: Task<Void, Never>?

    public init() {}

    public func cancel() {
        activeTask?.cancel()
    }

    public func scan(url: URL) -> AsyncStream<ScanProgress> {
        activeTask?.cancel()
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()

        activeTask = Task {
            let counter = ProgressCounter()
            let visited = VisitedSet()
            let config = ScanConfig.loadFromUserDefaults()

            // Emit periodic progress updates every 0.2s
            let progressTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let s = counter.snapshot
                    continuation.yield(.update(itemsScanned: s.items, bytesFound: s.bytes))
                }
            }

            do {
                let root = try await _buildTree(rootPath: url.path, rootURL: url, counter: counter, visited: visited, config: config)
                progressTask.cancel()
                continuation.yield(.completed(root: root, deniedCount: counter.deniedCount))
            } catch is CancellationError {
                progressTask.cancel()
            } catch {
                progressTask.cancel()
                continuation.yield(.failed(error.localizedDescription))
            }
            continuation.finish()
        }

        return stream
    }
}

// MARK: - Iterative work-stack tree builder (free functions, not actor-isolated)
//
// Concurrency invariant: a directory's `FSNode.children` array is written by
// exactly one worker (the one that processes that directory's work item), and
// every child FSNode is created by the parent's worker before being handed to
// the shared queue as a new work item. So no two workers ever touch the same
// node's mutable state concurrently, even though FSNode is `@unchecked Sendable`.

private struct DirWorkItem {
    let path: String
    let url: URL
    let node: FSNode
    // Identity recorded at discovery time (nil only for the scan root, which
    // was just lstat'd immediately before being opened). Re-checked via fstat
    // right after opening the directory, so a directory replaced in-between
    // (TOCTOU) is detected and skipped rather than silently scanned wrong.
    let expectedDev: UInt64?
    let expectedIno: UInt64?
}

// Bounded-concurrency work queue: a LIFO stack plus an in-flight counter.
// `pop()` returning nil doesn't mean "done" by itself - workers must also
// check `isFinished` (stack empty AND nothing in flight) before exiting, since
// another worker's current item may still push more work.
private final class WorkQueue: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var stack: [DirWorkItem]
    private var inFlight: Int

    init(seed: DirWorkItem) {
        stack = [seed]
        inFlight = 1
    }

    func push(_ item: DirWorkItem) {
        os_unfair_lock_lock(&lock)
        stack.append(item)
        inFlight += 1
        os_unfair_lock_unlock(&lock)
    }

    func pop() -> DirWorkItem? {
        os_unfair_lock_lock(&lock)
        let item = stack.popLast()
        os_unfair_lock_unlock(&lock)
        return item
    }

    // Call exactly once per item that was popped, after it has been fully
    // processed (including pushing any children it discovered).
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

private func _buildTree(
    rootPath: String,
    rootURL: URL,
    counter: ProgressCounter,
    visited: VisitedSet,
    config: ScanConfig
) async throws -> FSNode {
    try Task.checkCancellation()

    var st = stat()
    guard lstat(rootPath, &st) == 0 else {
        return FSNode(url: rootURL, name: rootURL.lastPathComponent, isDirectory: false, size: 0, fileExtension: "", parent: nil)
    }

    // Skip symlinks (including a symlink scan root).
    if st.st_mode & S_IFMT == S_IFLNK { throw SkipError() }

    let isDir = st.st_mode & S_IFMT == S_IFDIR
    let name = rootURL.lastPathComponent

    guard isDir else {
        // A file was passed directly as the scan root.
        let ext = rootURL.pathExtension.lowercased()
        let allocSize = allocatedSize(st: st, visited: visited)
        let node = FSNode(url: rootURL, name: name, isDirectory: false, size: allocSize, fileExtension: ext, parent: nil)
        if st.st_nlink > 1 { node.hardLinkRef = hardLinkRef(of: st) }
        counter.add(items: 1, bytes: allocSize)
        return node
    }

    let rootDevKey = UInt64(bitPattern: Int64(st.st_dev))
    let rootInoKey = UInt64(st.st_ino)
    // First visit of this scan always succeeds (fresh VisitedSet); kept for
    // symmetry with the dedup check every subdirectory goes through below.
    _ = visited.visit(dev: rootDevKey, ino: rootInoKey)

    let rootNode = FSNode(url: rootURL, name: name, isDirectory: true, size: 0, fileExtension: "", parent: nil)
    let seed = DirWorkItem(path: rootPath, url: rootURL, node: rootNode, expectedDev: rootDevKey, expectedIno: rootInoKey)
    let queue = WorkQueue(seed: seed)

    let workerCount = min(max(2, ProcessInfo.processInfo.activeProcessorCount / 2), 8)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<workerCount {
            group.addTask {
                try await _runWorker(queue: queue, rootDevKey: rootDevKey, counter: counter, visited: visited, config: config)
            }
        }
        try await group.waitForAll()
    }

    aggregateDirectorySizes(root: rootNode)
    return rootNode
}

private func _runWorker(
    queue: WorkQueue,
    rootDevKey: UInt64,
    counter: ProgressCounter,
    visited: VisitedSet,
    config: ScanConfig
) async throws {
    while true {
        try Task.checkCancellation()
        if let item = queue.pop() {
            try _processDirectory(item: item, rootDevKey: rootDevKey, counter: counter, visited: visited, config: config, queue: queue)
            continue
        }
        if queue.isFinished { return }
        await Task.yield()
    }
}

// Processes exactly one directory: opens it, lists its immediate children
// (bulk enumeration with fallback), applies all scan semantics, records
// direct file children + their sizes on `item.node`, and pushes any
// subdirectories as new work items. Always calls `queue.markDone()` exactly
// once, even on early return.
private func _processDirectory(
    item: DirWorkItem,
    rootDevKey: UInt64,
    counter: ProgressCounter,
    visited: VisitedSet,
    config: ScanConfig,
    queue: WorkQueue
) throws {
    defer { queue.markDone() }
    try Task.checkCancellation()

    let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        if errno == EACCES || errno == EPERM {
            item.node.isAccessDenied = true
            counter.addDenied()
        }
        counter.add(items: 1, bytes: 0)
        return
    }
    defer { close(fd) }

    if let expectedDev = item.expectedDev, let expectedIno = item.expectedIno {
        var st = stat()
        guard fstat(fd, &st) == 0,
              UInt64(bitPattern: Int64(st.st_dev)) == expectedDev,
              UInt64(st.st_ino) == expectedIno else {
            // The directory at this path was replaced between discovery and
            // open (TOCTOU race); drop it silently rather than scan the wrong thing.
            return
        }
    }

    let entries: [BulkDirEntry]
    do {
        entries = try listDirectoryEntries(path: item.path, fd: fd, forceFallback: config.forceFallbackEnum)
    } catch {
        // Enumeration failed even after falling back: treat as empty, not denied.
        counter.add(items: 1, bytes: 0)
        return
    }

    var directSize: Int64 = 0
    var children: [FSNode] = []
    children.reserveCapacity(entries.count)

    for (index, entry) in entries.enumerated() {
        if index % 256 == 0 {
            try Task.checkCancellation()
        }
        guard entry.name != "." && entry.name != ".." else { continue }
        if entry.name.hasPrefix("."), !config.showHiddenFiles { continue }
        if config.excludedNames.contains(entry.name) { continue }

        switch entry.kind {
        case .symlink, .other:
            continue

        case .directory:
            // Mount point: skip directories on a different device than the scan root.
            if entry.dev != rootDevKey { continue }
            // Dedup by (dev, ino): protects against firmlink aliases like
            // /Applications vs /System/Volumes/Data/Applications.
            guard visited.visit(dev: entry.dev, ino: entry.ino) else { continue }

            let childURL = item.url.appendingPathComponent(entry.name, isDirectory: true)
            let childNode = FSNode(url: childURL, name: entry.name, isDirectory: true, size: 0, fileExtension: "", parent: item.node)
            children.append(childNode)
            let childPath = item.path.hasSuffix("/") ? item.path + entry.name : item.path + "/" + entry.name
            queue.push(DirWorkItem(path: childPath, url: childURL, node: childNode, expectedDev: entry.dev, expectedIno: entry.ino))

        case .file:
            let childURL = item.url.appendingPathComponent(entry.name, isDirectory: false)
            let allocSize = bulkAllocatedSize(entry: entry, visited: visited)
            let ext = childURL.pathExtension.lowercased()
            let fileNode = FSNode(url: childURL, name: entry.name, isDirectory: false, size: allocSize, fileExtension: ext, parent: item.node)
            if entry.linkCount > 1 { fileNode.hardLinkRef = HardLinkRef(dev: entry.dev, ino: entry.ino) }
            children.append(fileNode)
            directSize += allocSize
            counter.add(items: 1, bytes: allocSize)
        }
    }

    item.node.children = children
    item.node.size = directSize
    counter.add(items: 1, bytes: 0)
}

// Picks bulk vs. fallback enumeration for one directory. If bulk enumeration
// throws partway through (having already consumed some of `fd`'s kernel-side
// listing position), the fallback re-opens the directory fresh by path so it
// always sees the complete, unconsumed listing rather than a partial remainder.
private func listDirectoryEntries(path: String, fd: Int32, forceFallback: Bool) throws -> [BulkDirEntry] {
    if forceFallback {
        return try fallbackEnumerateDirectory(fd: fd)
    }
    do {
        return try enumerateDirectoryBulk(fd: fd)
    } catch is BulkEnumerationUnavailable {
        let freshFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard freshFD >= 0 else { return [] }
        defer { close(freshFD) }
        return try fallbackEnumerateDirectory(fd: freshFD)
    }
}

// Iterative post-order pass: folds each directory's descendant directory
// sizes into its own `size` (which already holds its direct file sum from
// `_processDirectory`). Runs once, after all workers finish, so there is no
// concurrent mutation of node.size during traversal.
private func aggregateDirectorySizes(root: FSNode) {
    guard root.isDirectory else { return }

    // `order` ends up a valid pre-order (a node always precedes its own
    // descendants, since children are only pushed after their parent is
    // appended). Processing it in reverse guarantees every directory's
    // children are fully aggregated before the directory itself is folded
    // into its own parent.
    var order: [FSNode] = []
    var stack: [FSNode] = [root]
    while let node = stack.popLast() {
        order.append(node)
        for child in node.children where child.isDirectory {
            stack.append(child)
        }
    }

    for node in order.reversed() {
        var subtreeAddition: Int64 = 0
        for child in node.children where child.isDirectory {
            subtreeAddition += child.size
        }
        node.size += subtreeAddition
    }
}

// Builds the inode identity for a hardlinked file. dev_t is a signed 32-bit value
// (can be negative for synthetic filesystems), so use bit-pattern conversion.
private func hardLinkRef(of st: stat) -> HardLinkRef {
    HardLinkRef(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
}

// Returns the file's allocated disk bytes, deduplicating hardlinks via the visited set.
// Files with nlink == 1 skip the set entirely (fast path for the common case).
// Hardlinked files (nlink > 1) are counted only on their first encounter.
// Used only for a file passed directly as the scan root; regular directory
// listings use `bulkAllocatedSize` on the enumerator's own metadata instead.
private func allocatedSize(st: stat, visited: VisitedSet) -> Int64 {
    if st.st_nlink > 1 {
        guard visited.visit(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino)) else { return 0 }
    }
    return Int64(st.st_blocks) * 512
}

// Same dedup rule as `allocatedSize(st:visited:)` above, but sourced from a
// `BulkDirEntry` (either enumeration path) instead of a raw `stat`.
private func bulkAllocatedSize(entry: BulkDirEntry, visited: VisitedSet) -> Int64 {
    if entry.linkCount > 1 {
        guard visited.visit(dev: entry.dev, ino: entry.ino) else { return 0 }
    }
    return entry.allocatedSize
}

private struct SkipError: Error {}
