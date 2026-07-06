import Foundation

// Thread-safe set tracking visited (dev, ino) pairs to prevent double-counting.
// On macOS, /System/Volumes/Data/Applications shares the same inode as /Applications, etc.
private final class VisitedSet: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var set = Set<DevIno>()

    private struct DevIno: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    // Returns true if this (dev, ino) was NOT previously seen (and marks it seen).
    func visit(dev: dev_t, ino: ino_t) -> Bool {
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
            // Get the root device ID to detect mount points
            var rootStat = stat()
            let rootDev: dev_t? = (stat(url.path, &rootStat) == 0) ? rootStat.st_dev : nil

            // Emit periodic progress updates every 0.2s
            let progressTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let s = counter.snapshot
                    continuation.yield(.update(itemsScanned: s.items, bytesFound: s.bytes))
                }
            }

            do {
                let root = try await _buildTree(path: url.path, url: url, parent: nil, rootDev: rootDev, counter: counter, visited: visited)
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

// MARK: - POSIX-based parallel tree builder (free functions, not actor-isolated)

private func _buildTree(
    path: String,
    url: URL,
    parent: FSNode?,
    rootDev: dev_t?,
    counter: ProgressCounter,
    visited: VisitedSet
) async throws -> FSNode {
    try Task.checkCancellation()

    var st = stat()
    guard lstat(path, &st) == 0 else { return FSNode(url: url, name: url.lastPathComponent, isDirectory: false, size: 0, fileExtension: "", parent: parent) }

    // Skip symlinks
    if st.st_mode & S_IFMT == S_IFLNK { throw SkipError() }

    let isDir = st.st_mode & S_IFMT == S_IFDIR

    // Deduplicate directories by (dev, ino) — prevents double-counting paths like
    // /Applications and /System/Volumes/Data/Applications (same inode, different paths).
    if isDir {
        guard visited.visit(dev: st.st_dev, ino: st.st_ino) else { throw SkipError() }
    }

    let name = url.lastPathComponent
    let ext = isDir ? "" : url.pathExtension.lowercased()

    let node = FSNode(url: url, name: name, isDirectory: isDir, size: 0, fileExtension: ext, parent: parent)

    if isDir {
        let listing = _listDirectory(path: path, url: url, rootDev: rootDev, node: node, counter: counter, visited: visited)

        // Accumulate direct file sizes immediately
        node.size = listing.totalSize
        node.children = listing.children
        node.isAccessDenied = listing.accessDenied
        if listing.accessDenied { counter.addDenied() }

        // Recurse into subdirectories in parallel
        if !listing.subdirPaths.isEmpty {
            var subdirSize: Int64 = 0
            try await withThrowingTaskGroup(of: FSNode?.self) { group in
                for (subPath, subURL) in listing.subdirPaths {
                    group.addTask {
                        // Propagate cancellation; silently skip symlinks / unreadable entries.
                        try Task.checkCancellation()
                        do {
                            return try await _buildTree(path: subPath, url: subURL, parent: node, rootDev: rootDev, counter: counter, visited: visited)
                        } catch is SkipError {
                            return nil
                        }
                    }
                }
                for try await child in group {
                    guard let child else { continue }
                    node.children.append(child)
                    subdirSize += child.size
                }
            }
            node.size += subdirSize
        }

        counter.add(items: 1, bytes: 0)
    } else {
        // Allocated size: st_blocks * 512 gives actual disk usage
        let allocatedSize = Int64(st.st_blocks) * 512
        node.size = allocatedSize
        counter.add(items: 1, bytes: allocatedSize)
    }

    return node
}

private struct SubdirEntry {
    let path: String
    let url: URL
}

private struct DirectoryContents {
    var children: [FSNode]       // immediate file children already created
    var subdirPaths: [(String, URL)]  // subdirectory (path, url) pairs for parallel recursion
    var totalSize: Int64         // sum of immediate file sizes
    var itemCount: Int           // count of items processed here
    var accessDenied: Bool = false  // true when opendir failed due to permissions (EACCES/EPERM)
}

private func _listDirectory(path: String, url: URL, rootDev: dev_t?, node: FSNode, counter: ProgressCounter, visited: VisitedSet) -> DirectoryContents {
    var result = DirectoryContents(children: [], subdirPaths: [], totalSize: 0, itemCount: 0)

    guard let dir = opendir(path) else {
        if errno == EACCES || errno == EPERM {
            result.accessDenied = true
        }
        return result
    }
    defer { closedir(dir) }
    let directoryFD = dirfd(dir)

    let rawExcluded = UserDefaults.standard.string(forKey: "excludedFolderNames")
        ?? ".git,node_modules,DerivedData,.Trash"
    let excludedNames = Set(rawExcluded.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

    while let entry = readdir(dir) {
        let nameBytes = entry.pointee.d_name
        let name: String = withUnsafeBytes(of: nameBytes) { ptr in
            let bytes = ptr.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        guard name != "." && name != ".." else { continue }
        if name.hasPrefix("."), !UserDefaults.standard.bool(forKey: "showHiddenFiles") { continue }
        if excludedNames.contains(name) { continue }

        let childURL = url.appendingPathComponent(name, isDirectory: entry.pointee.d_type == DT_DIR)
        let dtype = entry.pointee.d_type

        // Fast type check using d_type from dirent (avoids extra stat call for most entries)
        if dtype == DT_LNK { continue }  // skip symlinks

        if dtype == DT_DIR || dtype == DT_UNKNOWN {
            // For DT_UNKNOWN (e.g. some network filesystems), use lstat
            var st = stat()
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
            if dtype == DT_UNKNOWN {
                guard fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFLNK { continue }
                if mode != S_IFDIR {
                    // It's a regular file with DT_UNKNOWN
                    let allocSize = allocatedSize(st: st, visited: visited)
                    let ext = childURL.pathExtension.lowercased()
                    let fileNode = FSNode(url: childURL, name: name, isDirectory: false, size: allocSize, fileExtension: ext, parent: node)
                    result.children.append(fileNode)
                    result.totalSize += allocSize
                    result.itemCount += 1
                    counter.add(items: 1, bytes: allocSize)
                    continue
                }
                // Check mount point via st_dev
                if let rootDev, st.st_dev != rootDev { continue }
                result.subdirPaths.append((childPath, childURL))
            } else {
                // DT_DIR — check mount point via a quick stat
                if let rootDev {
                    guard fstatat(directoryFD, name, &st, 0) == 0 else { continue }
                    if st.st_dev != rootDev { continue }
                }
                result.subdirPaths.append((childPath, childURL))
            }
        } else if dtype == DT_REG {
            var st = stat()
            guard fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let allocSize = allocatedSize(st: st, visited: visited)
            let ext = childURL.pathExtension.lowercased()
            let fileNode = FSNode(url: childURL, name: name, isDirectory: false, size: allocSize, fileExtension: ext, parent: node)
            result.children.append(fileNode)
            result.totalSize += allocSize
            result.itemCount += 1
            counter.add(items: 1, bytes: allocSize)
        }
        // DT_FIFO, DT_CHR, DT_BLK, DT_SOCK — skip
    }

    return result
}

// Returns the file's allocated disk bytes, deduplicating hardlinks via the visited set.
// Files with nlink == 1 skip the set entirely (fast path for the common case).
// Hardlinked files (nlink > 1) are counted only on their first encounter.
private func allocatedSize(st: stat, visited: VisitedSet) -> Int64 {
    if st.st_nlink > 1 {
        guard visited.visit(dev: st.st_dev, ino: st.st_ino) else { return 0 }
    }
    return Int64(st.st_blocks) * 512
}

private struct SkipError: Error {}
