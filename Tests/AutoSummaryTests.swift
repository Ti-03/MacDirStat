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
