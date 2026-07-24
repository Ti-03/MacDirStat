import XCTest
@testable import MacDirStat

// Coverage for `FileTree.removingSubtree(at:)` / `removingSubtrees(at:)` — the
// prune-on-trash replacement for the old "trash then full rescan" flow (see
// `ScanViewModel.trashNode`/`trashNodes`). These are pure, synchronous tree
// operations, so they're tested directly against hand-built fixtures without
// touching the filesystem or the Trash.
final class FileTreePruneTests: XCTestCase {

    // Builds a small FSNode fixture:
    //   root (/scan)                         size 900
    //     ├── big.bin (500)
    //     └── sub (dir)                      size 400
    //          ├── a.txt (300)
    //          └── b.txt (100)
    private func makeFixture() -> (root: FSNode, big: FSNode, sub: FSNode, a: FSNode, b: FSNode) {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big = FSNode(url: URL(fileURLWithPath: "/scan/big.bin"), name: "big.bin", isDirectory: false, size: 500, fileExtension: "bin", parent: root)
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 400, fileExtension: "", parent: root)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 300, fileExtension: "txt", parent: sub)
        let b = FSNode(url: URL(fileURLWithPath: "/scan/sub/b.txt"), name: "b.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: sub)
        sub.children = [a, b]
        root.children = [big, sub]
        root.size = big.size + sub.size
        return (root, big, sub, a, b)
    }

    private func node(named name: String, in tree: FileTree) -> FileNode {
        for i in 0..<tree.records.count where tree.records[i].name == name {
            return FileNode(tree: tree, index: i)
        }
        fatalError("no node named \(name) in tree fixture")
    }

    // Cheap topology validator shared by every test below: every childIndices
    // entry is in range, parentIndex round-trips back through childIndices,
    // and every node's children stay sorted size-desc.
    private func assertValidTopology(_ tree: FileTree, file: StaticString = #filePath, line: UInt = #line) {
        let count = tree.records.count
        for i in 0..<count {
            let start = tree.childStart[i]
            let cnt = tree.childCount[i]
            XCTAssertTrue(start >= 0 && start + cnt <= tree.childIndices.count, "child span out of range at \(i)", file: file, line: line)
            var previousSize: Int64? = nil
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

    // MARK: - removingSubtree: single removal

    func test_removingSubtree_leaf_reduces_record_count_by_one() {
        let (root, _, sub, a, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let aNode = node(named: "a.txt", in: tree)
        _ = sub; _ = a

        let pruned = tree.removingSubtree(at: aNode.index)

        XCTAssertEqual(pruned.records.count, tree.records.count - 1)
        assertValidTopology(pruned)
    }

    func test_removingSubtree_reduces_every_ancestor_by_exactly_the_removed_size() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let aNode = node(named: "a.txt", in: tree)
        let removedSize = aNode.size // 300

        let pruned = tree.removingSubtree(at: aNode.index)

        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.size, 400 - removedSize)
        XCTAssertEqual(newRoot.size, 900 - removedSize)
    }

    func test_removingSubtree_directory_removes_whole_subtree_and_reduces_only_direct_ancestors() {
        let (root, _, sub, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let subNode = node(named: "sub", in: tree)
        _ = sub

        let pruned = tree.removingSubtree(at: subNode.index)

        // sub + a.txt + b.txt all gone -> 3 fewer records than the original 5.
        XCTAssertEqual(pruned.records.count, tree.records.count - 3)
        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        XCTAssertEqual(newRoot.children.map(\.name), ["big.bin"])
        XCTAssertEqual(newRoot.size, 500, "root size must drop by the whole removed subtree's size (400), not just sub's direct children")
        assertValidTopology(pruned)
    }

    func test_removingSubtree_preserves_sort_order_and_sibling_subtrees() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let aNode = node(named: "a.txt", in: tree)

        let pruned = tree.removingSubtree(at: aNode.index)

        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        // big.bin(500) must still sort ahead of the shrunk sub(100).
        XCTAssertEqual(newRoot.children.map(\.name), ["big.bin", "sub"])
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.children.map(\.name), ["b.txt"])
    }

    func test_removingSubtree_path_reconstruction_still_correct_for_survivors() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let aNode = node(named: "a.txt", in: tree)

        let pruned = tree.removingSubtree(at: aNode.index)

        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        XCTAssertEqual(newRoot.url.path, "/scan")
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.url.path, "/scan/sub")
        let newB = newSub.children.first { $0.name == "b.txt" }!
        XCTAssertEqual(newB.url.path, "/scan/sub/b.txt")
        let newBig = newRoot.children.first { $0.name == "big.bin" }!
        XCTAssertEqual(newBig.url.path, "/scan/big.bin")
    }

    func test_removingSubtree_leaves_original_tree_untouched() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let originalCount = tree.records.count
        let originalRootSize = tree.records[tree.rootIndex].size
        let aNode = node(named: "a.txt", in: tree)

        _ = tree.removingSubtree(at: aNode.index)

        XCTAssertEqual(tree.records.count, originalCount, "original tree must not mutate")
        XCTAssertEqual(tree.records[tree.rootIndex].size, originalRootSize, "original tree's root size must not mutate")
    }

    func test_removingSubtree_at_root_returns_self_unchanged() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")

        let result = tree.removingSubtree(at: tree.rootIndex)

        XCTAssertTrue(result === tree, "removing the root must be a no-op, returning the same instance")
    }

    func test_removingSubtree_carries_over_duplicate_group_and_safety_fields_on_survivors() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let bigNode = node(named: "big.bin", in: tree)
        let groupID = UUID()
        tree.setDuplicateGroupID(groupID, at: bigNode.index)
        tree.setSafety(.safe, at: bigNode.index)
        let aNode = node(named: "a.txt", in: tree)

        let pruned = tree.removingSubtree(at: aNode.index)

        let prunedBig = node(named: "big.bin", in: pruned)
        XCTAssertEqual(prunedBig.duplicateGroupID, groupID)
        XCTAssertEqual(prunedBig.safetyLevel, .safe)
    }

    // MARK: - removingSubtrees: multiple removals

    func test_removingSubtrees_disjoint_nodes_reduces_each_ancestor_chain_independently() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let aNode = node(named: "a.txt", in: tree)   // under sub
        let bigNode = node(named: "big.bin", in: tree) // under root directly

        let pruned = tree.removingSubtrees(at: [aNode.index, bigNode.index])

        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        XCTAssertEqual(newRoot.children.map(\.name), ["sub"])
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.size, 400 - 300, "sub must lose exactly a.txt's size")
        XCTAssertEqual(newRoot.size, 900 - 300 - 500, "root must lose both removed subtrees' sizes, once each")
        assertValidTopology(pruned)
    }

    func test_removingSubtrees_nested_indices_does_not_double_count_ancestor_size() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let subNode = node(named: "sub", in: tree)
        let aNode = node(named: "a.txt", in: tree) // already inside sub's subtree

        // Passing both sub and one of its own descendants must behave exactly
        // like removing sub alone — a.txt's size must not be subtracted twice.
        let pruned = tree.removingSubtrees(at: [subNode.index, aNode.index])

        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        XCTAssertEqual(newRoot.children.map(\.name), ["big.bin"])
        XCTAssertEqual(newRoot.size, 900 - 400)
        assertValidTopology(pruned)
    }

    func test_removingSubtrees_empty_indices_returns_self() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")

        let result = tree.removingSubtrees(at: [])

        XCTAssertTrue(result === tree)
    }

    func test_removingSubtrees_out_of_range_index_is_ignored() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")

        let result = tree.removingSubtrees(at: [999])

        XCTAssertTrue(result === tree, "an out-of-range seed must be a no-op, not a crash")
    }

    func test_removingSubtrees_duplicate_index_in_list_removed_once() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let aNode = node(named: "a.txt", in: tree)

        let pruned = tree.removingSubtrees(at: [aNode.index, aNode.index])

        let newRoot = FileNode(tree: pruned, index: pruned.rootIndex)
        XCTAssertEqual(newRoot.size, 900 - 300, "duplicate seeds in the list must not subtract twice")
        assertValidTopology(pruned)
    }
}

// MARK: - ScanViewModel-level integration

// Unlike the pure-tree tests above, this one exercises the real
// `ScanViewModel.trashNode` entry point end to end: a real scan of a temp
// directory, a real `FileManager.trashItem` call, and the resulting prune
// updating `tree`/`selectedNode`/`extensionSummaries`/`duplicateGroups`
// in place instead of the old "trash then full rescan" behavior.
@MainActor
final class ScanViewModelPruneTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_trashNode_prunes_tree_in_place_without_rescanning() async throws {
        let prior = UserDefaults.standard.object(forKey: "realtimeMonitoring") as? Bool
        UserDefaults.standard.set(false, forKey: "realtimeMonitoring")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "realtimeMonitoring") }
            else { UserDefaults.standard.removeObject(forKey: "realtimeMonitoring") }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data(repeating: 1, count: 4096).write(to: tmp.appendingPathComponent("keep.bin"))
        let toDeleteURL = tmp.appendingPathComponent("delete-me.bin")
        try Data(repeating: 2, count: 2048).write(to: toDeleteURL)

        let vm = ScanViewModel()
        vm.updateLayoutSize(CGSize(width: 400, height: 400))
        vm.scan(url: tmp)
        await waitUntil { !vm.isScanning && !vm.isComputingLayout }

        guard let root = vm.root else { return XCTFail("scan should populate a root") }
        let originalTotal = root.size
        guard let target = root.children.first(where: { $0.name == "delete-me.bin" }) else {
            return XCTFail("expected delete-me.bin among the scanned children")
        }
        let targetSize = target.size
        vm.select(target)

        let trashed = vm.trashNode(target)
        XCTAssertTrue(trashed, "trashNode should report success for a real, trashable file")

        // The prune itself (tree/selection/drillStack/colorMap) is synchronous;
        // only the off-thread extension-summary/duplicate-group passes need
        // waiting for.
        XCTAssertFalse(FileManager.default.fileExists(atPath: toDeleteURL.path), "trashItem should have actually moved the file out of tmp")
        guard let newRoot = vm.root else { return XCTFail("tree must still exist after a prune") }
        XCTAssertEqual(newRoot.children.map(\.name), ["keep.bin"], "the trashed node must be gone from the live tree")
        XCTAssertEqual(newRoot.size, originalTotal - targetSize, "root size must shrink by exactly the trashed node's size")
        XCTAssertNil(vm.selectedNode, "the node that was selected and then trashed must be deselected, not left dangling")

        await waitUntil { vm.extensionSummaries.first(where: { $0.ext == ".bin" })?.fileCount == 1 }
        let binSummary = vm.extensionSummaries.first { $0.ext == ".bin" }
        XCTAssertEqual(binSummary?.fileCount, 1, "extension summaries must be recomputed against the pruned tree")
    }
}
