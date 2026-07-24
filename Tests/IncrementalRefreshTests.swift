import XCTest
@testable import MacDirStat

// Coverage for the Phase 4d incremental splice refresh: `FileTree.replacingSubtree(at:with:)`
// (the pure tree-topology algorithm) and `ScanViewModel.splicedTree(afterChangeAt:in:)` (the
// per-directory-rescan-and-splice orchestration that `handleFileSystemChanges` now uses instead
// of a full rescan on every FSEvents notification).
final class IncrementalRefreshTests: XCTestCase {

    // MARK: - FileTree.replacingSubtree: pure algorithm

    // Builds the same small fixture FileTreePruneTests uses:
    //   root (/scan)                         size 900
    //     ├── big.bin (500)
    //     └── sub (dir)                      size 400
    //          ├── a.txt (300)
    //          └── b.txt (100)
    private func makeFixtureTree() -> FileTree {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big = FSNode(url: URL(fileURLWithPath: "/scan/big.bin"), name: "big.bin", isDirectory: false, size: 500, fileExtension: "bin", parent: root)
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 400, fileExtension: "", parent: root)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 300, fileExtension: "txt", parent: sub)
        let b = FSNode(url: URL(fileURLWithPath: "/scan/sub/b.txt"), name: "b.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: sub)
        sub.children = [a, b]
        root.children = [big, sub]
        root.size = big.size + sub.size
        return FileTreeBuilder.build(from: root, rootPath: "/scan")
    }

    private func node(named name: String, in tree: FileTree) -> FileNode {
        for i in 0..<tree.records.count where tree.records[i].name == name {
            return FileNode(tree: tree, index: i)
        }
        fatalError("no node named \(name) in tree fixture")
    }

    private func assertValidTopology(_ tree: FileTree, file: StaticString = #filePath, line: UInt = #line) {
        let count = tree.records.count
        for i in 0..<count {
            let start = tree.childStart[i]
            let cnt = tree.childCount[i]
            XCTAssertTrue(start >= 0 && start + cnt <= tree.childIndices.count, "child span out of range at \(i)", file: file, line: line)
            var previousSize: Int64?
            for offset in 0..<cnt {
                let child = tree.childIndices[start + offset]
                XCTAssertTrue(child >= 0 && child < count, "child index \(child) out of range", file: file, line: line)
                XCTAssertEqual(tree.parentIndex[child], i, "child \(child)'s parentIndex must point back to \(i)", file: file, line: line)
                let size = tree.records[child].size
                if let previousSize {
                    XCTAssertGreaterThanOrEqual(previousSize, size, "children must stay sorted size-desc", file: file, line: line)
                }
                previousSize = size
            }
        }
        XCTAssertEqual(tree.parentIndex[tree.rootIndex], -1, "root must have no parent", file: file, line: line)
    }

    // A "freshly rescanned sub" replacement: a.txt shrinks 300->200, b.txt is
    // gone, c.txt (50) is new -> new sub totals 250 (was 400).
    private func makeShrunkSubtree() -> FileTree {
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 200, fileExtension: "txt", parent: sub)
        let c = FSNode(url: URL(fileURLWithPath: "/scan/sub/c.txt"), name: "c.txt", isDirectory: false, size: 50, fileExtension: "txt", parent: sub)
        sub.children = [a, c]
        sub.size = 250
        return FileTreeBuilder.build(from: sub, rootPath: "/scan/sub")
    }

    // A "freshly rescanned sub" replacement that grew past big.bin's 500,
    // to exercise the ancestor re-sort path.
    private func makeGrownSubtree() -> FileTree {
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big2 = FSNode(url: URL(fileURLWithPath: "/scan/sub/big2.bin"), name: "big2.bin", isDirectory: false, size: 600, fileExtension: "bin", parent: sub)
        sub.children = [big2]
        sub.size = 600
        return FileTreeBuilder.build(from: sub, rootPath: "/scan/sub")
    }

    func test_replacingSubtree_shrinks_ancestor_sizes_by_exact_delta() {
        let tree = makeFixtureTree()
        let subNode = node(named: "sub", in: tree)
        let replacement = makeShrunkSubtree()

        let spliced = tree.replacingSubtree(at: subNode.index, with: replacement)

        let newRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        XCTAssertEqual(newRoot.size, 900 - 400 + 250, "root size must reflect exactly the size delta of the replaced subtree")
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.size, 250)
        assertValidTopology(spliced)
    }

    func test_replacingSubtree_replaces_node_set_under_target() {
        let tree = makeFixtureTree()
        let subNode = node(named: "sub", in: tree)
        let replacement = makeShrunkSubtree()

        let spliced = tree.replacingSubtree(at: subNode.index, with: replacement)

        let newRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(Set(newSub.children.map(\.name)), Set(["a.txt", "c.txt"]), "b.txt must be gone, c.txt must be present")
        XCTAssertNil(newSub.children.first { $0.name == "b.txt" })
        let newA = newSub.children.first { $0.name == "a.txt" }!
        XCTAssertEqual(newA.size, 200, "a.txt's size must reflect the fresh rescan, not the stale one")
    }

    func test_replacingSubtree_preserves_untouched_sibling() {
        let tree = makeFixtureTree()
        let subNode = node(named: "sub", in: tree)
        let replacement = makeShrunkSubtree()

        let spliced = tree.replacingSubtree(at: subNode.index, with: replacement)

        let newRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        let bigStill = newRoot.children.first { $0.name == "big.bin" }
        XCTAssertNotNil(bigStill)
        XCTAssertEqual(bigStill?.size, 500, "an untouched sibling subtree must be completely unaffected by the splice")
    }

    func test_replacingSubtree_path_reconstruction_correct_for_spliced_and_survivors() {
        let tree = makeFixtureTree()
        let subNode = node(named: "sub", in: tree)
        let replacement = makeShrunkSubtree()

        let spliced = tree.replacingSubtree(at: subNode.index, with: replacement)

        let newRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        XCTAssertEqual(newRoot.url.path, "/scan")
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.url.path, "/scan/sub")
        let newC = newSub.children.first { $0.name == "c.txt" }!
        XCTAssertEqual(newC.url.path, "/scan/sub/c.txt", "a brand-new spliced-in node must still reconstruct its path correctly")
        let bigStill = newRoot.children.first { $0.name == "big.bin" }!
        XCTAssertEqual(bigStill.url.path, "/scan/big.bin", "a surviving node's path must still be correct after the splice")
    }

    func test_replacingSubtree_resorts_ancestor_chain_when_target_grows_past_a_sibling() {
        let tree = makeFixtureTree()
        let subNode = node(named: "sub", in: tree)
        let replacement = makeGrownSubtree() // 600, now bigger than big.bin's 500

        let spliced = tree.replacingSubtree(at: subNode.index, with: replacement)

        let newRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        XCTAssertEqual(newRoot.children.map(\.name), ["sub", "big.bin"], "sub must now sort ahead of big.bin")
        assertValidTopology(spliced)
    }

    func test_replacingSubtree_leaves_original_tree_untouched() {
        let tree = makeFixtureTree()
        let subNode = node(named: "sub", in: tree)
        let replacement = makeShrunkSubtree()
        let originalRootSize = tree.records[tree.rootIndex].size
        let originalCount = tree.records.count

        _ = tree.replacingSubtree(at: subNode.index, with: replacement)

        XCTAssertEqual(tree.records[tree.rootIndex].size, originalRootSize, "the original tree must not mutate")
        XCTAssertEqual(tree.records.count, originalCount)
    }

    func test_replacingSubtree_at_root_returns_self_unchanged() {
        let tree = makeFixtureTree()
        let replacement = makeShrunkSubtree()

        let result = tree.replacingSubtree(at: tree.rootIndex, with: replacement)

        XCTAssertTrue(result === tree, "replacing the root must be a no-op, returning the same instance")
    }

    func test_replacingSubtree_carries_over_duplicate_group_and_safety_on_untouched_survivors() {
        let tree = makeFixtureTree()
        let bigNode = node(named: "big.bin", in: tree)
        let groupID = UUID()
        tree.setDuplicateGroupID(groupID, at: bigNode.index)
        tree.setSafety(.safe, at: bigNode.index)
        let subNode = node(named: "sub", in: tree)
        let replacement = makeShrunkSubtree()

        let spliced = tree.replacingSubtree(at: subNode.index, with: replacement)

        let splicedBig = node(named: "big.bin", in: spliced)
        XCTAssertEqual(splicedBig.duplicateGroupID, groupID)
        XCTAssertEqual(splicedBig.safetyLevel, .safe)
    }

    // MARK: - ScanViewModel.splicedTree: fallback cases

    func test_splicedTree_root_change_falls_back_to_nil() {
        let tree = makeFixtureTree()

        XCTAssertNil(ScanViewModel.splicedTree(afterChangeAt: "/scan", in: tree))
    }

    func test_splicedTree_root_change_with_trailing_slash_falls_back_to_nil() {
        let tree = makeFixtureTree()

        XCTAssertNil(ScanViewModel.splicedTree(afterChangeAt: "/scan/", in: tree))
    }

    func test_splicedTree_unresolvable_path_falls_back_to_nil() {
        let tree = makeFixtureTree()

        XCTAssertNil(ScanViewModel.splicedTree(afterChangeAt: "/scan/does/not/exist", in: tree))
    }

    func test_splicedTree_path_outside_tree_falls_back_to_nil() {
        let tree = makeFixtureTree()

        XCTAssertNil(ScanViewModel.splicedTree(afterChangeAt: "/somewhere/else", in: tree))
    }

    func test_splicedTree_autosummarized_target_falls_back_to_nil() {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let bigDir = FSNode(url: URL(fileURLWithPath: "/scan/node_modules"), name: "node_modules", isDirectory: true, size: 12_345, fileExtension: "", parent: root)
        bigDir.isAutoSummarized = true
        bigDir.descendantFileCount = 9_999
        root.children = [bigDir]
        root.size = bigDir.size
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")

        XCTAssertNil(ScanViewModel.splicedTree(afterChangeAt: "/scan/node_modules", in: tree), "a summarized node has no children to splice into")
    }

    func test_splicedTree_path_inside_autosummarized_node_falls_back_to_nil() {
        // Same fixture as above, but the "changed" path is one level deeper
        // than the summarized node itself — never materialized in the tree
        // at all, so the path-component walk simply can't resolve it.
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let bigDir = FSNode(url: URL(fileURLWithPath: "/scan/node_modules"), name: "node_modules", isDirectory: true, size: 12_345, fileExtension: "", parent: root)
        bigDir.isAutoSummarized = true
        root.children = [bigDir]
        root.size = bigDir.size
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")

        XCTAssertNil(ScanViewModel.splicedTree(afterChangeAt: "/scan/node_modules/some-package", in: tree))
    }

    // MARK: - Key correctness check: splice result == full fresh rescan

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct NodeSnapshot: Hashable {
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
    }

    // Flattens every descendant of `node` (node included, as "") into a
    // set keyed by its path relative to `node`'s own tree root — order- and
    // index-independent, so it's safe to compare across two entirely
    // separate `FileTree` instances built from independent scans.
    private func snapshot(_ root: FileNode) -> Set<NodeSnapshot> {
        var result: Set<NodeSnapshot> = []
        let rootPath = root.tree.rootPath
        func walk(_ n: FileNode) {
            let full = n.url.path
            let relative = full == rootPath ? "" : String(full.dropFirst(rootPath.count))
            result.insert(NodeSnapshot(relativePath: relative, isDirectory: n.isDirectory, size: n.size))
            for child in n.children { walk(child) }
        }
        walk(root)
        return result
    }

    @MainActor
    private func scanAndWait(_ url: URL) async -> ScanViewModel {
        let prior = UserDefaults.standard.object(forKey: "realtimeMonitoring") as? Bool
        UserDefaults.standard.set(false, forKey: "realtimeMonitoring")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "realtimeMonitoring") }
            else { UserDefaults.standard.removeObject(forKey: "realtimeMonitoring") }
        }
        let vm = ScanViewModel()
        vm.updateLayoutSize(CGSize(width: 400, height: 400))
        vm.scan(url: url)
        await waitUntil { !vm.isScanning && !vm.isComputingLayout }
        return vm
    }

    // The key correctness test the plan calls for: build a real tree from a
    // real temp directory (via the actual FileScanner, exactly like a real
    // scan), mutate a subdirectory on disk (add a file, remove a file,
    // resize a file, add a nested directory), splice just that directory via
    // `ScanViewModel.splicedTree`, and compare the result against an
    // entirely independent, from-scratch full rescan of the same now-mutated
    // directory tree (a second real `FileScanner` run via a second
    // `ScanViewModel`). The two must describe exactly the same node set and
    // sizes — a splice is only a cheaper way to arrive at the same state a
    // full rescan would.
    func test_splice_result_matches_full_fresh_rescan() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data(repeating: 1, count: 8192).write(to: tmp.appendingPathComponent("keep.bin"))
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: sub.appendingPathComponent("a.txt"))
        let toRemove = sub.appendingPathComponent("b.txt")
        try Data(repeating: 3, count: 2048).write(to: toRemove)
        let toResize = sub.appendingPathComponent("c.txt")
        try Data(repeating: 4, count: 1024).write(to: toResize)

        let before = await scanAndWait(tmp)
        guard let beforeTree = await before.tree else { return XCTFail("initial scan should populate a tree") }
        guard let subIndex = (0..<beforeTree.records.count).first(where: { beforeTree.records[$0].name == "sub" }) else {
            return XCTFail("expected 'sub' in the initial scan")
        }
        _ = subIndex

        // Mutate "sub" on disk: remove b.txt, grow c.txt, add a new file and
        // a brand-new nested directory.
        try FileManager.default.removeItem(at: toRemove)
        try Data(repeating: 5, count: 16_384).write(to: toResize)
        try Data(repeating: 6, count: 512).write(to: sub.appendingPathComponent("d.txt"))
        let nested = sub.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 256).write(to: nested.appendingPathComponent("e.txt"))

        guard let spliced = ScanViewModel.splicedTree(afterChangeAt: sub.path, in: beforeTree) else {
            return XCTFail("splice should succeed for a plain, non-summarized subdirectory")
        }

        let after = await scanAndWait(tmp)
        guard let afterTree = await after.tree else { return XCTFail("second full rescan should populate a tree") }

        let splicedRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        let afterRoot = FileNode(tree: afterTree, index: afterTree.rootIndex)

        XCTAssertEqual(snapshot(splicedRoot), snapshot(afterRoot), "a splice must describe exactly the same node set/sizes as a full fresh rescan of the same on-disk state")
        XCTAssertEqual(splicedRoot.size, afterRoot.size, "total sizes must match exactly")
    }

    // MARK: - ScanViewModel-level integration: handleFileSystemChanges itself

    @MainActor
    func test_scan_view_model_splices_on_directory_change_without_full_rescan() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data(repeating: 1, count: 8192).write(to: tmp.appendingPathComponent("keep.bin"))
        let sub = tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: sub.appendingPathComponent("a.txt"))

        let prior = UserDefaults.standard.object(forKey: "realtimeMonitoring") as? Bool
        UserDefaults.standard.set(false, forKey: "realtimeMonitoring")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "realtimeMonitoring") }
            else { UserDefaults.standard.removeObject(forKey: "realtimeMonitoring") }
        }

        let vm = ScanViewModel()
        vm.updateLayoutSize(CGSize(width: 400, height: 400))
        vm.scan(url: tmp)
        await waitUntil { !vm.isScanning && !vm.isComputingLayout }
        guard let originalTree = vm.tree else { return XCTFail("scan should populate a tree") }

        try Data(repeating: 9, count: 20_000).write(to: sub.appendingPathComponent("new.bin"))

        await vm.handleFileSystemChanges([sub.path])

        guard let newTree = vm.tree else { return XCTFail("tree must still exist after a splice") }
        XCTAssertFalse(newTree === originalTree, "handleFileSystemChanges should have installed a new (spliced) tree")
        guard let newSub = vm.root?.children.first(where: { $0.name == "sub" }) else {
            return XCTFail("sub must still be present after the splice")
        }
        XCTAssertEqual(Set(newSub.children.map(\.name)), Set(["a.txt", "new.bin"]), "the splice must reflect the on-disk addition")
    }

    // MARK: - BUG 2: splice must keep hardlink dedup across the splice boundary

    // Builds a real temp tree with one hardlinked pair split across two
    // sibling directories (`dirX/big.bin` <-> `dirY/link.bin`), the exact
    // shape of the plan's BUG 2 scenario. Returns the inode's `HardLinkRef`
    // so the tests below can find out, after the initial scan, which side
    // the scanner's first-seen-wins picked as the carrier (deterministic per
    // run, but not something the test should hard-code).
    private func makeHardlinkAcrossDirsFixture() throws -> (tmp: URL, ref: HardLinkRef) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let dirX = tmp.appendingPathComponent("dirX")
        let dirY = tmp.appendingPathComponent("dirY")
        try FileManager.default.createDirectory(at: dirX, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirY, withIntermediateDirectories: true)

        let bigPath = dirX.appendingPathComponent("big.bin")
        try Data(repeating: 9, count: 262_144).write(to: bigPath)
        try FileManager.default.linkItem(at: bigPath, to: dirY.appendingPathComponent("link.bin"))
        // An unrelated file in each directory so a splice of either side has
        // something else in it besides the hardlink half.
        try Data(repeating: 1, count: 128).write(to: dirX.appendingPathComponent("other.txt"))
        try Data(repeating: 2, count: 128).write(to: dirY.appendingPathComponent("other.txt"))

        var st = stat()
        XCTAssertEqual(lstat(bigPath.path, &st), 0)
        let ref = HardLinkRef(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
        return (tmp, ref)
    }

    // Finds the node sharing `ref` whose size does (or doesn't, per
    // `wantCarrier`) match the first-seen-wins carrier convention, then
    // climbs to its direct child-of-root directory name — "the directory
    // holding the carrier/twin" from the plan's scenario.
    private func topLevelDirName(carryingRef wantCarrier: Bool, ref: HardLinkRef, tree: FileTree) -> String? {
        for i in 0..<tree.records.count {
            guard tree.records[i].hardLinkRef == ref, (tree.records[i].size > 0) == wantCarrier else { continue }
            var current = i
            while tree.parentIndex[current] != tree.rootIndex {
                let p = tree.parentIndex[current]
                guard p >= 0 else { return nil }
                current = p
            }
            return tree.records[current].name
        }
        return nil
    }

    // Splicing the directory holding the NON-carrier (0-size) twin must not
    // re-materialize the full size a second time: the carrier lives outside
    // the spliced subtree, so it must be pre-seeded into `seenRefs` and the
    // rescanned copy must come back at 0, exactly as it was.
    func test_splice_of_directory_holding_hardlink_loser_matches_full_rescan_total() async throws {
        let (tmp, ref) = try makeHardlinkAcrossDirsFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let before = await scanAndWait(tmp)
        guard let beforeTree = await before.tree else { return XCTFail("initial scan should populate a tree") }
        guard let loserDirName = topLevelDirName(carryingRef: false, ref: ref, tree: beforeTree) else {
            return XCTFail("expected to find the hardlink's 0-size twin in the initial scan")
        }

        guard let spliced = ScanViewModel.splicedTree(afterChangeAt: tmp.appendingPathComponent(loserDirName).path, in: beforeTree) else {
            return XCTFail("splice should succeed for a plain, non-summarized subdirectory")
        }

        let after = await scanAndWait(tmp)
        guard let afterTree = await after.tree else { return XCTFail("second full rescan should populate a tree") }

        let splicedRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        let afterRoot = FileNode(tree: afterTree, index: afterTree.rootIndex)
        XCTAssertEqual(splicedRoot.size, afterRoot.size, "splicing the directory holding the hardlink LOSER must not double-count the carrier living outside it")
    }

    // The mirrored case: splicing the directory holding the CARRIER must let
    // the rescan re-take the full size for that (still 0-seeded-locally)
    // ref, while the untouched outside 0-size twin correctly stays at 0.
    func test_splice_of_directory_holding_hardlink_carrier_matches_full_rescan_total() async throws {
        let (tmp, ref) = try makeHardlinkAcrossDirsFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let before = await scanAndWait(tmp)
        guard let beforeTree = await before.tree else { return XCTFail("initial scan should populate a tree") }
        guard let carrierDirName = topLevelDirName(carryingRef: true, ref: ref, tree: beforeTree) else {
            return XCTFail("expected to find the hardlink carrier in the initial scan")
        }

        guard let spliced = ScanViewModel.splicedTree(afterChangeAt: tmp.appendingPathComponent(carrierDirName).path, in: beforeTree) else {
            return XCTFail("splice should succeed for a plain, non-summarized subdirectory")
        }

        let after = await scanAndWait(tmp)
        guard let afterTree = await after.tree else { return XCTFail("second full rescan should populate a tree") }

        let splicedRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        let afterRoot = FileNode(tree: afterTree, index: afterTree.rootIndex)
        XCTAssertEqual(splicedRoot.size, afterRoot.size, "splicing the directory holding the hardlink CARRIER must still match a full fresh rescan's total")
    }
}
