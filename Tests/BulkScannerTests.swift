import XCTest
@testable import MacDirStat

final class BulkScannerTests: XCTestCase {

    // MARK: - Helpers

    // Sorted (relativePath, isDirectory, size) fingerprint of an entire tree,
    // used to compare the bulk and fallback enumeration paths against each other.
    //
    // Hardlinked files need special handling: which specific link "wins" the
    // non-zero size (VisitedSet.visit is a first-come-first-served race across
    // concurrent workers) is real, expected nondeterminism of concurrent
    // traversal, not a correctness bug - verified directly, it can differ
    // between two runs of the *same* enumeration method on a hardlink-heavy
    // real tree (e.g. Xcode.app, which hardlinks tens of thousands of files
    // across sibling bundles), not just bulk vs fallback. Two consequences:
    //   - a hardlinked file's own size is normalized to 0 here and instead
    //     checked as a group: the same set of paths must share one inode, and
    //     that group's total allocated size must match.
    //   - a *directory's* aggregated size becomes nondeterministic too, if a
    //     hardlink's two links sit under different parents (the bytes get
    //     attributed to whichever parent's link happened to win). Only the
    //     grand total is guaranteed invariant. So directory entries carry no
    //     size at all here; only file entries and the root total do.
    private struct FileFingerprintEntry: Hashable {
        let relativePath: String
        let size: Int64
    }

    private struct HardlinkGroupFingerprint: Hashable {
        let paths: [String]
        let total: Int64
    }

    private struct Fingerprint {
        let fileEntries: [FileFingerprintEntry]
        let directoryPaths: [String]
        let hardlinkGroups: [HardlinkGroupFingerprint]
        let total: Int64
    }

    private func fingerprint(root: FileNode, base: URL) -> Fingerprint {
        var fileEntries: [FileFingerprintEntry] = []
        var directoryPaths: [String] = []
        var groups: [HardLinkRef: (paths: Set<String>, total: Int64)] = [:]

        func visit(_ node: FileNode) {
            let relativePath = String(node.url.path.dropFirst(base.path.count))
            if node.isDirectory {
                directoryPaths.append(relativePath)
            } else if let ref = node.hardLinkRef {
                var group = groups[ref] ?? (paths: [], total: 0)
                group.paths.insert(relativePath)
                group.total += node.size
                groups[ref] = group
                fileEntries.append(FileFingerprintEntry(relativePath: relativePath, size: 0))
            } else {
                fileEntries.append(FileFingerprintEntry(relativePath: relativePath, size: node.size))
            }
            for child in node.children { visit(child) }
        }
        visit(root)
        fileEntries.sort { $0.relativePath < $1.relativePath }
        directoryPaths.sort()

        let hardlinkGroups = groups.values
            .map { HardlinkGroupFingerprint(paths: $0.paths.sorted(), total: $0.total) }
            .sorted { $0.paths.first ?? "" < $1.paths.first ?? "" }

        return Fingerprint(fileEntries: fileEntries, directoryPaths: directoryPaths, hardlinkGroups: hardlinkGroups, total: root.size)
    }

    private func scanTree(at url: URL) async -> FileNode? {
        let scanner = FileScanner()
        var root: FileNode?
        for await progress in await scanner.scan(url: url) {
            if case .completed(let tree, _) = progress { root = FileNode(tree: tree, index: tree.rootIndex) }
        }
        return root
    }

    // Builds a tree exercising every scan semantic: nested dirs, hidden files,
    // an excluded dir name, a symlink, a hardlink pair, and a file > 4 KB.
    private func buildFixtureTree(at tmp: URL) throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sub = tmp.appendingPathComponent("sub")
        let nested = sub.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try Data(repeating: 0xAB, count: 8192).write(to: tmp.appendingPathComponent("big.bin"))
        try Data(repeating: 0, count: 16).write(to: sub.appendingPathComponent("small.txt"))
        try Data(repeating: 0, count: 16).write(to: nested.appendingPathComponent("deep.txt"))
        try Data(repeating: 0, count: 8).write(to: tmp.appendingPathComponent(".hidden"))

        let excludedDir = tmp.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: excludedDir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: excludedDir.appendingPathComponent("junk.bin"))

        let real = tmp.appendingPathComponent("real.bin")
        try Data(repeating: 1, count: 4096).write(to: real)
        let link = tmp.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let hard1 = sub.appendingPathComponent("hard1.bin")
        let hard2 = sub.appendingPathComponent("hard2.bin")
        try Data(repeating: 3, count: 262_144).write(to: hard1)
        try FileManager.default.linkItem(at: hard1, to: hard2)
    }

    // MARK: - 1. Parity fingerprint test

    func test_bulk_and_fallback_enumeration_produce_identical_fingerprint() async throws {
        let priorValue = UserDefaults.standard.string(forKey: "excludedFolderNames")
        UserDefaults.standard.set(".git,node_modules,DerivedData,.Trash", forKey: "excludedFolderNames")
        defer {
            if let priorValue { UserDefaults.standard.set(priorValue, forKey: "excludedFolderNames") }
            else { UserDefaults.standard.removeObject(forKey: "excludedFolderNames") }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try buildFixtureTree(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let bulkRoot = await scanTree(at: tmp) else {
            return XCTFail("bulk scan produced no root")
        }
        let bulkFingerprint = fingerprint(root: bulkRoot, base: tmp)

        setenv("MDS_FORCE_FALLBACK_ENUM", "1", 1)
        let fallbackRoot = await scanTree(at: tmp)
        unsetenv("MDS_FORCE_FALLBACK_ENUM")

        guard let fallbackRoot else {
            return XCTFail("fallback scan produced no root")
        }
        let fallbackFingerprint = fingerprint(root: fallbackRoot, base: tmp)

        XCTAssertEqual(bulkFingerprint.fileEntries, fallbackFingerprint.fileEntries, "bulk and fallback enumeration must see the same files with the same sizes")
        XCTAssertEqual(bulkFingerprint.directoryPaths, fallbackFingerprint.directoryPaths, "bulk and fallback enumeration must see the same directories")
        XCTAssertEqual(bulkFingerprint.hardlinkGroups, fallbackFingerprint.hardlinkGroups, "hardlink groupings and their total sizes must match")
        XCTAssertEqual(bulkFingerprint.total, fallbackFingerprint.total, "bulk and fallback totals must match")
        XCTAssertGreaterThan(bulkFingerprint.total, 0)
    }

    // MARK: - 2. Bulk enumerator unit test

    func test_bulk_enumerator_matches_lstat_ground_truth() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("a.bin")
        let fileB = tmp.appendingPathComponent("b.bin")
        let dirC = tmp.appendingPathComponent("c_dir")
        try Data(repeating: 1, count: 12_345).write(to: fileA)
        try Data(repeating: 2, count: 42).write(to: fileB)
        try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)

        let fd = open(tmp.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        let entries = try enumerateDirectoryBulk(fd: fd)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        XCTAssertEqual(entries.count, 3)

        for name in ["a.bin", "b.bin", "c_dir"] {
            guard let entry = byName[name] else {
                XCTFail("missing entry for \(name)")
                continue
            }
            var st = stat()
            XCTAssertEqual(lstat(tmp.appendingPathComponent(name).path, &st), 0)
            XCTAssertEqual(entry.dev, UInt64(bitPattern: Int64(st.st_dev)), "dev mismatch for \(name)")
            XCTAssertEqual(entry.ino, UInt64(st.st_ino), "ino mismatch for \(name)")
            if name == "c_dir" {
                XCTAssertEqual(entry.kind, .directory)
            } else {
                XCTAssertEqual(entry.kind, .file)
                XCTAssertEqual(entry.linkCount, UInt32(st.st_nlink), "linkCount mismatch for \(name)")
                XCTAssertEqual(entry.allocatedSize, Int64(st.st_blocks) * 512, "allocatedSize mismatch for \(name)")
            }
        }
    }

    // MARK: - 3. Hardlink dedup test

    func test_hardlinked_file_deduped_across_two_directories() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dirA = tmp.appendingPathComponent("dirA")
        let dirB = tmp.appendingPathComponent("dirB")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = dirA.appendingPathComponent("orig.bin")
        try Data(repeating: 9, count: 262_144).write(to: original)
        let linked = dirB.appendingPathComponent("linked.bin")
        try FileManager.default.linkItem(at: original, to: linked)

        var st = stat()
        XCTAssertEqual(lstat(original.path, &st), 0)
        let fullSize = Int64(st.st_blocks) * 512

        guard let root = await scanTree(at: tmp) else {
            return XCTFail("scan produced no root")
        }

        let aNode = root.children.first { $0.name == "dirA" }
        let bNode = root.children.first { $0.name == "dirB" }
        let origNode = aNode?.children.first { $0.name == "orig.bin" }
        let linkedNode = bNode?.children.first { $0.name == "linked.bin" }

        XCTAssertNotNil(origNode?.hardLinkRef)
        XCTAssertNotNil(linkedNode?.hardLinkRef)
        XCTAssertEqual(origNode?.hardLinkRef, linkedNode?.hardLinkRef)

        let sizes = [origNode?.size ?? -1, linkedNode?.size ?? -1].sorted()
        XCTAssertEqual(sizes, [0, fullSize], "one link carries the full size, the other is zero")
        XCTAssertEqual(root.size, fullSize, "the shared inode must be counted exactly once across both directories")
    }

    // MARK: - 4. Access-denied test

    func test_unreadable_subdirectory_marked_access_denied() async throws {
        guard getuid() != 0 else {
            throw XCTSkip("running as root: chmod 000 does not block access")
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let locked = tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: locked.appendingPathComponent("secret.bin"))

        chmod(locked.path, 0)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: tmp)
        }

        var deniedCount = 0
        let scanner = FileScanner()
        var root: FileNode?
        for await progress in await scanner.scan(url: tmp) {
            if case .completed(let tree, let denied) = progress {
                root = FileNode(tree: tree, index: tree.rootIndex)
                deniedCount = denied
            }
        }

        let lockedNode = root?.children.first { $0.name == "locked" }
        XCTAssertNotNil(lockedNode)
        XCTAssertTrue(lockedNode?.isAccessDenied ?? false)
        XCTAssertEqual(lockedNode?.children.count, 0)
        XCTAssertGreaterThanOrEqual(deniedCount, 1)
    }

    // MARK: - 5. Cancellation test

    func test_cancellation_ends_stream_without_completed() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A moderately large synthetic tree so the scan is very unlikely to
        // finish before cancellation takes effect.
        for i in 0..<50 {
            let dir = tmp.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for j in 0..<50 {
                try Data(repeating: 0, count: 256).write(to: dir.appendingPathComponent("f\(j).bin"))
            }
        }

        let scanner = FileScanner()
        var sawCompleted = false
        let stream = await scanner.scan(url: tmp)
        let consumeTask = Task {
            for await progress in stream {
                if case .completed = progress { sawCompleted = true }
            }
        }
        await scanner.cancel()
        _ = await consumeTask.value

        XCTAssertFalse(sawCompleted, "a cancelled scan must not emit .completed")
    }

    // MARK: - 7. Env-gated benchmark

    func test_benchmark_bulk_vs_fallback() async throws {
        guard ProcessInfo.processInfo.environment["MDS_BENCH"] == "1" else {
            throw XCTSkip("set MDS_BENCH=1 to run the benchmark")
        }
        let path = ProcessInfo.processInfo.environment["MDS_BENCH_PATH"] ?? "/Applications"
        let url = URL(fileURLWithPath: path)

        let bulkStart = DispatchTime.now()
        guard let bulkRoot = await scanTree(at: url) else {
            return XCTFail("bulk benchmark scan produced no root")
        }
        let bulkElapsed = Double(DispatchTime.now().uptimeNanoseconds - bulkStart.uptimeNanoseconds) / 1_000_000_000

        setenv("MDS_FORCE_FALLBACK_ENUM", "1", 1)
        let fallbackStart = DispatchTime.now()
        let fallbackRoot = await scanTree(at: url)
        let fallbackElapsed = Double(DispatchTime.now().uptimeNanoseconds - fallbackStart.uptimeNanoseconds) / 1_000_000_000
        unsetenv("MDS_FORCE_FALLBACK_ENUM")

        guard let fallbackRoot else {
            return XCTFail("fallback benchmark scan produced no root")
        }

        let bulkFingerprint = fingerprint(root: bulkRoot, base: url)
        let fallbackFingerprint = fingerprint(root: fallbackRoot, base: url)

        print("MDS_BENCH elapsed_bulk=\(bulkElapsed) elapsed_fallback=\(fallbackElapsed) path=\(path)")

        if bulkFingerprint.fileEntries != fallbackFingerprint.fileEntries {
            let bulkSet = Set(bulkFingerprint.fileEntries.map { "\($0.relativePath)|\($0.size)" })
            let fallbackSet = Set(fallbackFingerprint.fileEntries.map { "\($0.relativePath)|\($0.size)" })
            let onlyBulk = bulkSet.subtracting(fallbackSet)
            let onlyFallback = fallbackSet.subtracting(bulkSet)
            print("MDS_BENCH_DIFF onlyBulk=\(onlyBulk.count) onlyFallback=\(onlyFallback.count)")
            for line in onlyBulk.sorted().prefix(20) { print("MDS_BENCH_ONLY_BULK \(line)") }
            for line in onlyFallback.sorted().prefix(20) { print("MDS_BENCH_ONLY_FALLBACK \(line)") }
        }
        if bulkFingerprint.directoryPaths != fallbackFingerprint.directoryPaths {
            let bulkSet = Set(bulkFingerprint.directoryPaths)
            let fallbackSet = Set(fallbackFingerprint.directoryPaths)
            print("MDS_BENCH_DIFF onlyBulkDirs=\(bulkSet.subtracting(fallbackSet).count) onlyFallbackDirs=\(fallbackSet.subtracting(bulkSet).count)")
        }
        if bulkFingerprint.hardlinkGroups != fallbackFingerprint.hardlinkGroups {
            print("MDS_BENCH_DIFF hardlinkGroups bulk=\(bulkFingerprint.hardlinkGroups.count) fallback=\(fallbackFingerprint.hardlinkGroups.count)")
        }

        XCTAssertEqual(bulkFingerprint.fileEntries, fallbackFingerprint.fileEntries, "bulk and fallback enumeration must see the same files with the same sizes")
        XCTAssertEqual(bulkFingerprint.directoryPaths, fallbackFingerprint.directoryPaths, "bulk and fallback enumeration must see the same directories")
        XCTAssertEqual(bulkFingerprint.hardlinkGroups, fallbackFingerprint.hardlinkGroups, "hardlink groupings and their total sizes must match")
        XCTAssertEqual(bulkFingerprint.total, fallbackFingerprint.total)
    }

    // MARK: - Firmlinked directories must be scanned, not silently dropped
    //
    // Regression test for the worst bug this scanner has had. macOS firmlinks
    // (/Users, /Applications, /Library, /opt, /private, /Volumes, /cores) are
    // recorded on the sealed system volume with their own inode, and resolve
    // on open to a different inode on the Data volume. The scanner used to
    // compare the enumerated (dev, ino) against the opened one as a TOCTOU
    // guard and drop the directory when they disagreed — which threw away
    // every firmlink, i.e. essentially all user data. Scanning "/" reported
    // 11.8 GB instead of 479.3 GB on the development machine.
    //
    // The existing bulk-vs-fallback parity test could never have caught this:
    // its fixture is a plain temp directory, which has no firmlinks and no
    // mount points. This one scans the real startup volume shallowly, so it
    // exercises the actual platform behaviour.
    //
    // Kept cheap and robust: it only asserts that the well-known firmlinked
    // directories are present with a non-zero size, which requires no
    // knowledge of the machine's contents and no full-disk walk.
    func test_startup_volume_firmlinks_are_scanned() async throws {
        // /Users is a firmlink on every modern macOS install; if it isn't
        // readable at all (sandboxed CI, no permissions) there is nothing
        // meaningful to assert.
        guard FileManager.default.isReadableFile(atPath: "/Users") else {
            throw XCTSkip("/Users is not readable in this environment")
        }

        var rootStat = stat()
        var usersStat = stat()
        guard lstat("/", &rootStat) == 0, lstat("/Users", &usersStat) == 0 else {
            throw XCTSkip("could not stat / and /Users")
        }
        // The bug only exists where the enumerated and resolved identities
        // differ, which is what makes a path a firmlink. On a volume layout
        // without firmlinks there is nothing to regress.
        guard rootStat.st_dev == usersStat.st_dev else {
            throw XCTSkip("unexpected volume layout: /Users is on another device")
        }

        // Scan "/" itself but keep it cheap: exclude the large subtrees, so
        // this walks the top level and stops. The point is whether the
        // firmlinked entries survive traversal at all, not their exact sizes.
        let prior = UserDefaults.standard.string(forKey: "excludedFolderNames")
        UserDefaults.standard.set("System,usr,bin,sbin,dev,.Trash", forKey: "excludedFolderNames")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "excludedFolderNames") }
            else { UserDefaults.standard.removeObject(forKey: "excludedFolderNames") }
        }

        let scanner = FileScanner()
        var root: FileNode?
        for await progress in await scanner.scan(url: URL(fileURLWithPath: "/")) {
            if case .completed(let tree, _) = progress { root = FileNode(tree: tree, index: tree.rootIndex) }
        }
        guard let root else { return XCTFail("scanning / produced no tree") }

        guard let users = root.children.first(where: { $0.name == "Users" }) else {
            return XCTFail("/Users is missing from the scan entirely — firmlinks are being dropped")
        }
        XCTAssertGreaterThan(
            users.size, 0,
            "/Users scanned as 0 bytes — the firmlinked directory was traversed but produced nothing"
        )
    }
}
