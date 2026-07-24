import XCTest
@testable import MacDirStat

final class AutoSummaryTests: XCTestCase {

    // MARK: - Helpers

    private func withAutoSummarize<T>(_ enabled: Bool, _ body: () async throws -> T) async rethrows -> T {
        let prior = UserDefaults.standard.object(forKey: "autoSummarizeEnabled")
        UserDefaults.standard.set(enabled, forKey: "autoSummarizeEnabled")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "autoSummarizeEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "autoSummarizeEnabled") }
        }
        return try await body()
    }

    private func withMinFileCountOverride<T>(_ value: Int, _ body: () async throws -> T) async rethrows -> T {
        setenv("MDS_SUMMARY_MIN_FILES", "\(value)", 1)
        defer { unsetenv("MDS_SUMMARY_MIN_FILES") }
        return try await body()
    }

    // The app's default excludedFolderNames already contains "node_modules"
    // (it is fully skipped, not just collapsed - see ScanConfig's default in
    // FileScanner.swift), so tests exercising the node_modules named-layout
    // shortcut must use a config where it is NOT excluded, exactly like a
    // user who removed it from their exclusion list would see.
    private func withExcludedFolderNames<T>(_ names: String, _ body: () async throws -> T) async rethrows -> T {
        let prior = UserDefaults.standard.string(forKey: "excludedFolderNames")
        UserDefaults.standard.set(names, forKey: "excludedFolderNames")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "excludedFolderNames") }
            else { UserDefaults.standard.removeObject(forKey: "excludedFolderNames") }
        }
        return try await body()
    }

    private func scanTree(at url: URL) async -> FileNode? {
        let scanner = FileScanner()
        var root: FileNode?
        for await progress in await scanner.scan(url: url) {
            if case .completed(let tree, _) = progress { root = FileNode(tree: tree, index: tree.rootIndex) }
        }
        return root
    }

    // Recursively counts every non-directory FileNode (normal leaf files) plus
    // every isAutoSummarized node's descendantFileCount, so summarized and
    // non-summarized scans of the same tree can be compared on a "how many
    // files did we account for" basis.
    private func totalAccountedFiles(_ node: FileNode) -> Int {
        if node.isAutoSummarized { return node.descendantFileCount }
        if !node.isDirectory { return 1 }
        return node.children.reduce(0) { $0 + totalAccountedFiles($1) }
    }

    // Regression test for the summary-pool forward-progress hazard.
    //
    // `summarizeSubtree` used to keep a synchronous signature and bridge into
    // its nested worker pool by blocking the calling thread on a
    // DispatchSemaphore. Because the caller runs on a Swift-concurrency
    // cooperative thread and the nested pool needs threads from that same
    // pool, enough SIMULTANEOUS summaries could block every cooperative
    // thread waiting on work that had no thread left to run on. A wedged
    // summary also pins the main scan's in-flight count above zero, so
    // `WorkQueue.isFinished` never trips and every other scan worker spins
    // forever - one stuck summary hung the entire scan, and cancelling did
    // not recover it.
    //
    // This builds many sibling directories that ALL trip summarization at
    // once (far more than the worker-pool cap, so the scheduler is forced to
    // overlap them) and asserts the scan still completes with correct totals.
    // Against the old blocking bridge this is the shape that could hang;
    // with the pool awaited directly it simply finishes.
    func test_many_concurrent_summaries_complete_without_stalling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 24 siblings >> the 8-worker cap on either pool, so many summaries
        // are guaranteed to be in flight at the same time. Each candidate is
        // named `node_modules` so it summarizes via the deterministic
        // named-layout shortcut rather than depending on the filesystem's
        // allocated-size rounding to satisfy the average-size heuristic.
        let siblingCount = 24
        let filesPerSibling = 12
        var expectedFiles = 0

        for s in 0..<siblingCount {
            let holder = root.appendingPathComponent("pkg\(s)", isDirectory: true)
            let target = holder.appendingPathComponent("node_modules", isDirectory: true)
            // A nested dir inside each summarized subtree so the nested pool
            // actually has queued work rather than returning on the fast path.
            let deeper = target.appendingPathComponent("inner", isDirectory: true)
            try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)

            for f in 0..<filesPerSibling {
                try Data(repeating: 7, count: 16).write(to: target.appendingPathComponent("f\(f).dat"))
                expectedFiles += 1
            }
            try Data(repeating: 8, count: 16).write(to: deeper.appendingPathComponent("deep.dat"))
            expectedFiles += 1
        }

        // node_modules is excluded outright by the shipped defaults, so drop it
        // from the exclusion list to actually exercise summarization here.
        let summarized = await withExcludedFolderNames(".git,DerivedData,.Trash") {
            await withAutoSummarize(true) { await scanTree(at: root) }
        }
        guard let summarized else { return XCTFail("summarized scan produced no root") }

        let full = await withExcludedFolderNames(".git,DerivedData,.Trash") {
            await withAutoSummarize(false) { await scanTree(at: root) }
        }
        guard let full else { return XCTFail("full scan produced no root") }

        // Completion alone is the hang regression; these assert it also stayed correct.
        XCTAssertEqual(summarized.size, full.size, "concurrent summaries must not change total size")
        XCTAssertEqual(totalAccountedFiles(summarized), expectedFiles)
        XCTAssertEqual(totalAccountedFiles(full), expectedFiles)

        let summarizedCount = countSummarized(summarized)
        XCTAssertEqual(summarizedCount, siblingCount, "every sibling cache dir should have summarized")
    }

    private func countSummarized(_ node: FileNode) -> Int {
        (node.isAutoSummarized ? 1 : 0) + node.children.reduce(0) { $0 + countSummarized($1) }
    }

    // The other half of the forward-progress bug: with the old blocking
    // bridge, the poll loop only forwarded cancellation to the detached pool
    // and kept spinning, so a wedged summary could not be recovered by
    // "Stop Scan" at all.
    //
    // Drives `summarizeSubtree` DIRECTLY with a cancel closure that throws
    // partway through, rather than cancelling a whole scan. An end-to-end
    // scan-then-cancel test looks like it covers this but does not: the
    // cancellation almost always lands during the initial traversal, before
    // any summary walk has begun, so the test passes even with every
    // cancellation check inside the summary path deleted (verified by
    // mutation). Calling the walk directly is deterministic and actually
    // fails if the walk stops honouring `cancel`.
    func test_summary_walk_propagates_cancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Enough nested directories that the walk makes many cancel() calls.
        for d in 0..<40 {
            let deep = root.appendingPathComponent("m\(d)", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            for f in 0..<10 {
                try Data(repeating: 1, count: 32).write(to: deep.appendingPathComponent("f\(f).dat"))
            }
        }

        var st = stat()
        XCTAssertEqual(lstat(root.path, &st), 0)
        let rootDev = UInt64(bitPattern: Int64(st.st_dev))

        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let rootEntries = try listDirectoryEntries(path: root.path, fd: fd, forceFallback: false)

        struct StopWalking: Error {}
        // Let a few directories through, then refuse to continue.
        let callCount = Counter()
        let config = ScanConfig(
            excludedNames: [],
            showHiddenFiles: false,
            forceFallbackEnum: false,
            autoSummarizeEnabled: true
        )

        do {
            _ = try await summarizeSubtree(
                rootEntries: rootEntries,
                rootPath: root.path,
                rootDev: rootDev,
                config: config,
                visited: VisitedSet()
            ) {
                if callCount.increment() > 5 { throw StopWalking() }
            }
            XCTFail("summarizeSubtree must propagate the cancel closure's error, not swallow it")
        } catch is StopWalking {
            // Expected: the walk asked, was told to stop, and unwound.
        }
    }

    // Thread-safe call counter: the summary pool invokes `cancel` from
    // several workers at once.
    private final class Counter: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var value = 0
        func increment() -> Int {
            os_unfair_lock_lock(&lock)
            value += 1
            let result = value
            os_unfair_lock_unlock(&lock)
            return result
        }
    }

    // Complements the direct test above: a full scan with summarization
    // enabled must still cancel cleanly and never emit `.completed`.
    func test_cancelled_scan_with_summarization_never_completes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Enough summarizable siblings, each with real depth and file count,
        // that a full uncancelled scan takes appreciable time.
        for s in 0..<12 {
            let holder = root.appendingPathComponent("pkg\(s)", isDirectory: true)
            let target = holder.appendingPathComponent("node_modules", isDirectory: true)
            for d in 0..<12 {
                let deep = target.appendingPathComponent("m\(d)", isDirectory: true)
                try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
                for f in 0..<25 {
                    try Data(repeating: 9, count: 64).write(to: deep.appendingPathComponent("f\(f).dat"))
                }
            }
        }

        let elapsed: Double = await withExcludedFolderNames(".git,DerivedData,.Trash") {
            await withAutoSummarize(true) {
                let scanner = FileScanner()
                var sawCompleted = false
                let stream = await scanner.scan(url: root)
                let start = DispatchTime.now()
                let consumeTask = Task {
                    for await progress in stream {
                        if case .completed = progress { sawCompleted = true }
                    }
                }
                await scanner.cancel()
                _ = await consumeTask.value
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

                XCTAssertFalse(sawCompleted, "a scan cancelled during summarization must not emit .completed")
                return seconds
            }
        }

        // Generous bound: the point is "it unwinds", not a precise deadline.
        // Against a wedged pool this would never return at all.
        XCTAssertLessThan(elapsed, 10.0, "cancellation during a summary walk should tear down promptly")
    }

    private func findNode(_ root: FileNode, path: [String]) -> FileNode? {
        var current = root
        for name in path {
            guard let next = current.children.first(where: { $0.name == name }) else { return nil }
            current = next
        }
        return current
    }

    // Creates `count` small files spread across a couple of nested
    // subdirectories under `dir`, each `bytes` bytes long. Returns the total
    // allocated size (via lstat) of every file created, so tests can assert
    // an exact expected total without hardcoding filesystem block behavior.
    @discardableResult
    private func makeFiles(count: Int, bytes: Int, under dir: URL, nestedEvery: Int = 7) throws -> Int64 {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var total: Int64 = 0
        var currentDir = dir
        for i in 0..<count {
            if nestedEvery > 0, i > 0, i % nestedEvery == 0 {
                currentDir = currentDir.appendingPathComponent("nested\(i)")
                try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
            }
            let file = currentDir.appendingPathComponent("f\(i).bin")
            try Data(repeating: UInt8(i % 251), count: bytes).write(to: file)
            var st = stat()
            XCTAssertEqual(lstat(file.path, &st), 0)
            total += Int64(st.st_blocks) * 512
        }
        return total
    }

    // MARK: - 1. node_modules named-layout shortcut

    func test_node_modules_is_summarized() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let nodeModules = tmp.appendingPathComponent("proj").appendingPathComponent("node_modules")
        let expectedTotal = try makeFiles(count: 50, bytes: 16, under: nodeModules)

        guard let onRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(true, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan (autoSummarize on) produced no root")
        }
        guard let nmNode = findNode(onRoot, path: ["proj", "node_modules"]) else {
            return XCTFail("node_modules node not found")
        }

        XCTAssertTrue(nmNode.isAutoSummarized)
        XCTAssertTrue(nmNode.children.isEmpty)
        XCTAssertEqual(nmNode.descendantFileCount, 50)
        XCTAssertEqual(nmNode.size, expectedTotal)

        guard let offRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(false, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan (autoSummarize off) produced no root")
        }
        XCTAssertEqual(onRoot.size, offRoot.size, "collapsing node_modules must not change the root's total size")

        guard let offNmNode = findNode(offRoot, path: ["proj", "node_modules"]) else {
            return XCTFail("node_modules node not found in the non-summarized scan")
        }
        XCTAssertFalse(offNmNode.isAutoSummarized)
        XCTAssertEqual(offNmNode.children.isEmpty, false)
    }

    // MARK: - 2. General immediate-file-count heuristic (env-overridden threshold)

    func test_threshold_directory_summarized() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // depth: tmp=0, level1=1, tinyDir/bigDir=2 (>= minDepth).
        let level1 = tmp.appendingPathComponent("level1")
        let tinyDir = level1.appendingPathComponent("tinyDir")
        let bigDir = level1.appendingPathComponent("bigDir")

        // Empty files: allocatedSize 0, average 0 < maxAverageFileSize.
        try makeFiles(count: 10, bytes: 0, under: tinyDir, nestedEvery: 0)
        // 8 KB files: average clearly above maxAverageFileSize (4096).
        try makeFiles(count: 10, bytes: 8192, under: bigDir, nestedEvery: 0)

        guard let root = await withMinFileCountOverride(10, {
            await withAutoSummarize(true, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan produced no root")
        }

        guard let tinyNode = findNode(root, path: ["level1", "tinyDir"]) else {
            return XCTFail("tinyDir node not found")
        }
        XCTAssertTrue(tinyNode.isAutoSummarized, "many-tiny-file directory below the average-size threshold should be summarized")
        XCTAssertEqual(tinyNode.descendantFileCount, 10)

        guard let bigNode = findNode(root, path: ["level1", "bigDir"]) else {
            return XCTFail("bigDir node not found")
        }
        XCTAssertFalse(bigNode.isAutoSummarized, "directory whose average file size exceeds the threshold must not be summarized")
        XCTAssertEqual(bigNode.children.count, 10)
    }

    // MARK: - 3. autoSummarize off matches a full scan's sizes and file accounting

    func test_summarize_off_matches_full_scan_sizes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: tmp.appendingPathComponent("plain.bin"))

        let nodeModules = tmp.appendingPathComponent("node_modules")
        try makeFiles(count: 20, bytes: 16, under: nodeModules)

        guard let onRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(true, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan (autoSummarize on) produced no root")
        }
        guard let offRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(false, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan (autoSummarize off) produced no root")
        }

        XCTAssertEqual(onRoot.size, offRoot.size, "root size must be identical whether or not subtrees got collapsed")
        XCTAssertEqual(totalAccountedFiles(onRoot), totalAccountedFiles(offRoot), "every file must be accounted for exactly once in both modes")
        // 1 plain file + 20 files under node_modules.
        XCTAssertEqual(totalAccountedFiles(offRoot), 21)
    }

    // MARK: - 4. Hardlinks inside a summarized subtree are not double-counted

    func test_hardlinks_not_double_counted_in_summary() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let nodeModules = tmp.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)

        let hard1 = nodeModules.appendingPathComponent("hard1.bin")
        let hard2 = nodeModules.appendingPathComponent("hard2.bin")
        try Data(repeating: 3, count: 262_144).write(to: hard1)
        try FileManager.default.linkItem(at: hard1, to: hard2)
        try Data(repeating: 4, count: 16).write(to: nodeModules.appendingPathComponent("other.bin"))

        var st = stat()
        XCTAssertEqual(lstat(hard1.path, &st), 0)
        let hardlinkSize = Int64(st.st_blocks) * 512
        XCTAssertEqual(lstat(nodeModules.appendingPathComponent("other.bin").path, &st), 0)
        let otherSize = Int64(st.st_blocks) * 512

        guard let root = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(true, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan produced no root")
        }
        guard let nmNode = findNode(root, path: ["node_modules"]) else {
            return XCTFail("node_modules node not found")
        }

        XCTAssertTrue(nmNode.isAutoSummarized)
        XCTAssertEqual(nmNode.descendantFileCount, 3, "both hardlink names and the unrelated file are each one descendant file")
        XCTAssertEqual(nmNode.size, hardlinkSize + otherSize, "the hardlinked pair must contribute its allocated bytes exactly once")
    }

    // MARK: - 5. Parallel walk matches a serial (autoSummarize off) scan

    // Builds a moderately deep/wide tree that trips summarization (via a low
    // MDS_SUMMARY_MIN_FILES override), scans it with autoSummarize on (which
    // now drives the parallel worker pool in `summarizeSubtree`) and off
    // (full, per-file walk), and asserts the summarized node's aggregate
    // size and descendantFileCount exactly match the full scan's totals.
    // This is a determinism/parity check for the parallel accumulator: since
    // multiple workers race to discover directories/hardlinks, this is the
    // test that would catch any double-counting or dropped entries the
    // parallelization could introduce.
    func test_parallel_summary_matches_serial_for_nested_tree() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Use the node_modules named-layout shortcut (rather than the
        // immediate-file-count heuristic) so the tree can be wide - many
        // independent "package" subdirectories, each with its own shallow
        // nested chain - without needing files directly inside node_modules
        // itself. Wide-and-shallow, rather than one long chained path, is
        // what actually makes the parallel pool fan out across many workers
        // while staying well under macOS's path-length limit.
        let nodeModules = tmp.appendingPathComponent("proj").appendingPathComponent("node_modules")
        var expectedTotal: Int64 = 0
        for pkg in 0..<20 {
            expectedTotal += try makeFiles(count: 20, bytes: 32, under: nodeModules.appendingPathComponent("pkg\(pkg)"), nestedEvery: 3)
        }

        guard let onRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(true, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan (autoSummarize on) produced no root")
        }
        guard let nmNode = findNode(onRoot, path: ["proj", "node_modules"]) else {
            return XCTFail("node_modules node not found")
        }
        XCTAssertTrue(nmNode.isAutoSummarized, "node_modules-named directory should trip summarization")

        guard let offRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(false, { await scanTree(at: tmp) })
        }) else {
            return XCTFail("scan (autoSummarize off) produced no root")
        }
        guard let offNmNode = findNode(offRoot, path: ["proj", "node_modules"]) else {
            return XCTFail("node_modules node not found in the non-summarized scan")
        }

        XCTAssertEqual(nmNode.size, expectedTotal, "parallel summary walk must total exactly the bytes on disk")
        XCTAssertEqual(nmNode.descendantFileCount, 400, "parallel summary walk must count every file exactly once")
        XCTAssertEqual(nmNode.size, offNmNode.size, "parallel summary result must match a full serial scan's size")
        XCTAssertEqual(nmNode.descendantFileCount, totalAccountedFiles(offNmNode), "parallel summary result must match a full serial scan's file count")
    }

    // MARK: - 6. Env-gated benchmark

    func test_benchmark_autosummary() async throws {
        guard ProcessInfo.processInfo.environment["MDS_SUMMARY_BENCH"] == "1" else {
            throw XCTSkip("set MDS_SUMMARY_BENCH=1 to run the benchmark")
        }
        guard let path = ProcessInfo.processInfo.environment["MDS_SUMMARY_BENCH_PATH"] else {
            return XCTFail("set MDS_SUMMARY_BENCH_PATH to a directory containing a node_modules-heavy tree")
        }
        let url = URL(fileURLWithPath: path)

        func countNodes(_ node: FileNode) -> Int {
            1 + node.children.reduce(0) { $0 + countNodes($1) }
        }

        // The app's default excludedFolderNames already fully excludes
        // "node_modules" (see ScanConfig); drop it here so the benchmark
        // actually exercises the named-layout summarization path instead of
        // both runs skipping the tree identically.
        let onStart = DispatchTime.now()
        guard let onRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(true, { await scanTree(at: url) })
        }) else {
            return XCTFail("summarize-on benchmark scan produced no root")
        }
        let onElapsed = Double(DispatchTime.now().uptimeNanoseconds - onStart.uptimeNanoseconds) / 1_000_000_000

        let offStart = DispatchTime.now()
        guard let offRoot = await withExcludedFolderNames(".git,DerivedData,.Trash", {
            await withAutoSummarize(false, { await scanTree(at: url) })
        }) else {
            return XCTFail("summarize-off benchmark scan produced no root")
        }
        let offElapsed = Double(DispatchTime.now().uptimeNanoseconds - offStart.uptimeNanoseconds) / 1_000_000_000

        let nodesOn = countNodes(onRoot)
        let nodesOff = countNodes(offRoot)
        let rootBytesEqual = onRoot.size == offRoot.size

        print("MDS_SUMMARY_BENCH on=\(onElapsed) off=\(offElapsed) nodes_on=\(nodesOn) nodes_off=\(nodesOff) rootBytesEqual=\(rootBytesEqual)")

        XCTAssertTrue(rootBytesEqual, "auto-summarization must not change the total scanned size")
    }
}
