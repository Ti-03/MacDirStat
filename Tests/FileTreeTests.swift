import XCTest
@testable import MacDirStat

final class FileTreeTests: XCTestCase {

    // Builds a small FSNode fixture:
    //   root (/scan)
    //     ├── big.bin (500)
    //     └── sub (dir)
    //          ├── a.txt (300)
    //          └── b.txt (100)
    private func makeFixture() -> (root: FSNode, big: FSNode, sub: FSNode, a: FSNode, b: FSNode) {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big = FSNode(url: URL(fileURLWithPath: "/scan/big.bin"), name: "big.bin", isDirectory: false, size: 500, fileExtension: "bin", parent: root)
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 400, fileExtension: "", parent: root)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 300, fileExtension: "txt", parent: sub)
        let b = FSNode(url: URL(fileURLWithPath: "/scan/sub/b.txt"), name: "b.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: sub)
        sub.children = [a, b] // deliberately unsorted (a=300 before b=100 is fine, already desc)
        root.children = [sub, big] // deliberately NOT size-desc (big=500 should come first)
        root.size = big.size + sub.size
        return (root, big, sub, a, b)
    }

    // MARK: - Builder correctness

    func test_builder_root_index_is_zero() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        XCTAssertEqual(tree.rootIndex, 0)
        XCTAssertEqual(tree.records[tree.rootIndex].name, "scan")
        XCTAssertEqual(tree.parentIndex[tree.rootIndex], -1)
    }

    func test_builder_parent_links_are_correct() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        for child in rootNode.children {
            XCTAssertEqual(child.parent?.index, tree.rootIndex)
        }
        let subNode = rootNode.children.first { $0.name == "sub" }!
        for grandchild in subNode.children {
            XCTAssertEqual(grandchild.parent?.index, subNode.index)
        }
    }

    func test_builder_children_are_sorted_size_desc_regardless_of_fsnode_order() {
        let (root, _, _, _, _) = makeFixture()
        // FSNode fixture deliberately has children in [sub(400), big(500)] order.
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        let sizes = rootNode.children.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "builder must sort each node's children size-desc")
        XCTAssertEqual(rootNode.children.first?.name, "big.bin")

        let subNode = rootNode.children.first { $0.name == "sub" }!
        XCTAssertEqual(subNode.children.map(\.name), ["a.txt", "b.txt"], "a.txt (300) must sort before b.txt (100)")
    }

    func test_builder_child_spans_do_not_overlap() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        // Every index reachable from root's children arrays must be unique and
        // within bounds — a cheap proxy for "spans don't alias each other".
        var seen = Set<Int>()
        for index in 0..<tree.records.count {
            let start = tree.childStart[index]
            let count = tree.childCount[index]
            for offset in 0..<count {
                let childIndex = tree.childIndices[start + offset]
                XCTAssertTrue(childIndex >= 0 && childIndex < tree.records.count)
                XCTAssertTrue(seen.insert(childIndex).inserted, "child index \(childIndex) referenced by more than one parent")
            }
        }
    }

    func test_builder_leaf_has_no_children() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        let bigNode = rootNode.children.first { $0.name == "big.bin" }!
        XCTAssertEqual(bigNode.children.count, 0)
        XCTAssertNil(bigNode.optionalChildren)
    }

    // MARK: - Path reconstruction

    func test_path_of_root_is_root_path() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        XCTAssertEqual(tree.path(of: tree.rootIndex), "/scan")
    }

    func test_path_of_nested_node_joins_names() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        let subNode = rootNode.children.first { $0.name == "sub" }!
        let aNode = subNode.children.first { $0.name == "a.txt" }!
        XCTAssertEqual(subNode.url.path, "/scan/sub")
        XCTAssertEqual(aNode.url.path, "/scan/sub/a.txt")
    }

    func test_path_handles_trailing_slash_root_path() {
        let root = FSNode(url: URL(fileURLWithPath: "/"), name: "/", isDirectory: true, size: 10, fileExtension: "", parent: nil)
        let child = FSNode(url: URL(fileURLWithPath: "/Users"), name: "Users", isDirectory: true, size: 10, fileExtension: "", parent: root)
        root.children = [child]
        let tree = FileTreeBuilder.build(from: root, rootPath: "/")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        XCTAssertEqual(rootNode.children.first?.url.path, "/Users", "must not produce a double slash when rootPath already ends in '/'")
    }

    // MARK: - Record field carry-over

    func test_builder_carries_over_hardlink_ref_and_synthetic_and_autosummarized_flags() {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)

        let hardlinked = FSNode(url: URL(fileURLWithPath: "/scan/h.bin"), name: "h.bin", isDirectory: false, size: 200, fileExtension: "bin", parent: root)
        hardlinked.hardLinkRef = HardLinkRef(dev: 1, ino: 42)

        let summarized = FSNode(url: URL(fileURLWithPath: "/scan/node_modules"), name: "node_modules", isDirectory: true, size: 900, fileExtension: "", parent: root)
        summarized.isAutoSummarized = true
        summarized.descendantFileCount = 123

        let synthetic = FSNode(url: URL(fileURLWithPath: "/scan/synthetic"), name: "synthetic", isDirectory: false, size: 50, fileExtension: "", parent: root)
        synthetic.isSynthetic = true

        let denied = FSNode(url: URL(fileURLWithPath: "/scan/denied"), name: "denied", isDirectory: true, size: 0, fileExtension: "", parent: root)
        denied.isAccessDenied = true

        root.children = [hardlinked, summarized, synthetic, denied]
        root.size = 1200

        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)

        let hNode = rootNode.children.first { $0.name == "h.bin" }!
        XCTAssertEqual(hNode.hardLinkRef, HardLinkRef(dev: 1, ino: 42))

        let nmNode = rootNode.children.first { $0.name == "node_modules" }!
        XCTAssertTrue(nmNode.isAutoSummarized)
        XCTAssertEqual(nmNode.descendantFileCount, 123)

        let synNode = rootNode.children.first { $0.name == "synthetic" }!
        XCTAssertTrue(synNode.isSynthetic)

        let deniedNode = rootNode.children.first { $0.name == "denied" }!
        XCTAssertTrue(deniedNode.isAccessDenied)

        // Per the design, safetyLevel/duplicateGroupID always start at their
        // defaults at assembly time — they're filled by a separate pass
        // (tagSafetyLevels / DuplicateDetector) over the finished FileTree.
        XCTAssertNil(hNode.duplicateGroupID)
        XCTAssertEqual(hNode.safetyLevel, .caution)
    }

    // MARK: - Mutation

    func test_set_duplicate_group_id_and_safety_and_size() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        let bigNode = rootNode.children.first { $0.name == "big.bin" }!

        let groupID = UUID()
        tree.setDuplicateGroupID(groupID, at: bigNode.index)
        XCTAssertEqual(FileNode(tree: tree, index: bigNode.index).duplicateGroupID, groupID)

        tree.setSafety(.danger, at: bigNode.index)
        XCTAssertEqual(FileNode(tree: tree, index: bigNode.index).safetyLevel, .danger)

        tree.setSize(999, at: bigNode.index)
        XCTAssertEqual(FileNode(tree: tree, index: bigNode.index).size, 999)
    }

    // MARK: - Synthetic root child (topology-changing splice used for hidden-space)

    func test_appending_synthetic_root_child_inserts_in_sorted_position() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        // Root's children before: [big.bin(500), sub(400)]. A synthetic entry
        // of 450 bytes should land between them.
        let newTree = tree.appendingSyntheticRootChild(name: "Hidden & Unreadable Space", size: 450)
        let newRoot = FileNode(tree: newTree, index: newTree.rootIndex)

        XCTAssertEqual(newRoot.children.map(\.name), ["big.bin", "Hidden & Unreadable Space", "sub"])
        XCTAssertTrue(newRoot.children[1].isSynthetic)
        XCTAssertEqual(newRoot.children[1].safetyLevel, .danger)
        XCTAssertEqual(newRoot.size, 500 + 400 + 450, "root's aggregate size must include the synthetic child")
    }

    func test_appending_synthetic_root_child_leaves_original_tree_untouched() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let originalChildCount = FileNode(tree: tree, index: tree.rootIndex).children.count
        let originalSize = tree.records[tree.rootIndex].size

        _ = tree.appendingSyntheticRootChild(name: "Hidden & Unreadable Space", size: 450)

        XCTAssertEqual(FileNode(tree: tree, index: tree.rootIndex).children.count, originalChildCount, "original tree's topology must not mutate")
        XCTAssertEqual(tree.records[tree.rootIndex].size, originalSize, "original tree's root size must not mutate")
    }

    func test_appending_synthetic_root_child_preserves_other_subtrees() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let newTree = tree.appendingSyntheticRootChild(name: "Hidden & Unreadable Space", size: 450)
        let newRoot = FileNode(tree: newTree, index: newTree.rootIndex)

        let subNode = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(subNode.children.map(\.name), ["a.txt", "b.txt"], "unrelated subtree's children/order must survive the splice")
        XCTAssertEqual(subNode.url.path, "/scan/sub")
    }

    // The synthetic node used to be appended to `records` and `parentIndex`
    // without a matching entry in `childStart`/`childCount`, leaving the tree
    // one span short of its own record count. Nothing noticed until some later
    // pass iterated every record and read its span — which crashed the app
    // with "Index out of range" (see the splice test below). Every per-node
    // array must stay the same length.
    func test_appending_synthetic_root_child_keeps_all_per_node_arrays_in_step() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        let newTree = tree.appendingSyntheticRootChild(name: "Hidden & Unreadable Space", size: 450)

        let count = newTree.records.count
        XCTAssertEqual(newTree.parentIndex.count, count, "parentIndex must have one entry per record")
        XCTAssertEqual(newTree.childStart.count, count, "childStart must have one entry per record")
        XCTAssertEqual(newTree.childCount.count, count, "childCount must have one entry per record")

        // Reading every node's span must be in range and internally sane.
        for i in 0..<count {
            let start = newTree.childStart[i]
            let cnt = newTree.childCount[i]
            XCTAssertTrue(start >= 0 && start + cnt <= newTree.childIndices.count, "span out of range for node \(i)")
        }
    }

    // The crash a user actually hit: scan a volume root (which appends the
    // synthetic "Hidden & Unreadable Space" child), then let a live
    // filesystem change splice a subtree. `replacingSubtree` walks every
    // record and reads its span, so the missing entry blew up on the main
    // thread and killed the app.
    func test_splicing_a_tree_that_has_a_synthetic_child_does_not_crash() {
        let (root, _, _, _, _) = makeFixture()
        let tree = FileTreeBuilder
            .build(from: root, rootPath: "/scan")
            .appendingSyntheticRootChild(name: "Hidden & Unreadable Space", size: 450)

        let subIndex = (0..<tree.records.count).first { tree.records[$0].name == "sub" }!

        let replacement = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 120, fileExtension: "", parent: nil)
        let onlyChild = FSNode(url: URL(fileURLWithPath: "/scan/sub/new.txt"), name: "new.txt", isDirectory: false, size: 120, fileExtension: "txt", parent: replacement)
        replacement.children = [onlyChild]
        let subtree = FileTreeBuilder.build(from: replacement, rootPath: "/scan/sub")

        let spliced = tree.replacingSubtree(at: subIndex, with: subtree)

        let newRoot = FileNode(tree: spliced, index: spliced.rootIndex)
        XCTAssertTrue(
            newRoot.children.contains { $0.isSynthetic },
            "the synthetic hidden-space child must survive a splice elsewhere in the tree"
        )
        let newSub = newRoot.children.first { $0.name == "sub" }!
        XCTAssertEqual(newSub.children.map(\.name), ["new.txt"])
        XCTAssertEqual(newRoot.size, 500 + 120 + 450, "root size must reflect the spliced subtree plus the synthetic child")
    }
}
