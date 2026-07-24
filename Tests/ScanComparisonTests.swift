import XCTest
@testable import MacDirStat

final class ScanComparisonTests: XCTestCase {

    // "Before" fixture:
    //   root (/scan)
    //     ├── big.bin (500)         -- shrinks to 100 in "after"
    //     ├── sub (dir, 400)
    //     │    ├── a.txt (300)      -- grows to 350 in "after"
    //     │    └── b.txt (100)      -- unchanged
    //     └── oldDir (dir, 200)     -- entirely removed in "after"
    //          └── oldFile.txt (200)
    private func makeBeforeTree() -> FileTree {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big = FSNode(url: URL(fileURLWithPath: "/scan/big.bin"), name: "big.bin", isDirectory: false, size: 500, fileExtension: "bin", parent: root)
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 400, fileExtension: "", parent: root)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 300, fileExtension: "txt", parent: sub)
        let b = FSNode(url: URL(fileURLWithPath: "/scan/sub/b.txt"), name: "b.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: sub)
        sub.children = [a, b]

        let oldDir = FSNode(url: URL(fileURLWithPath: "/scan/oldDir"), name: "oldDir", isDirectory: true, size: 200, fileExtension: "", parent: root)
        let oldFile = FSNode(url: URL(fileURLWithPath: "/scan/oldDir/oldFile.txt"), name: "oldFile.txt", isDirectory: false, size: 200, fileExtension: "txt", parent: oldDir)
        oldDir.children = [oldFile]

        root.children = [big, sub, oldDir]
        root.size = big.size + sub.size + oldDir.size
        return FileTreeBuilder.build(from: root, rootPath: "/scan")
    }

    // "After" fixture: big.bin shrank, sub/a.txt grew, oldDir is gone
    // entirely, and a brand-new top-level file appeared.
    private func makeAfterTree() -> FileTree {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big = FSNode(url: URL(fileURLWithPath: "/scan/big.bin"), name: "big.bin", isDirectory: false, size: 100, fileExtension: "bin", parent: root)
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 450, fileExtension: "", parent: root)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 350, fileExtension: "txt", parent: sub)
        let b = FSNode(url: URL(fileURLWithPath: "/scan/sub/b.txt"), name: "b.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: sub)
        sub.children = [a, b]

        let newFile = FSNode(url: URL(fileURLWithPath: "/scan/newFile.txt"), name: "newFile.txt", isDirectory: false, size: 250, fileExtension: "txt", parent: root)

        root.children = [big, sub, newFile]
        root.size = big.size + sub.size + newFile.size
        return FileTreeBuilder.build(from: root, rootPath: "/scan")
    }

    func test_compare_reports_exactly_the_four_expected_changes() {
        let before = makeBeforeTree()
        let after = makeAfterTree()

        let changes = ScanComparison.compare(before: before, after: after)

        XCTAssertEqual(changes.count, 4, "must not list oldDir's descendant separately, or unrelated unchanged nodes")

        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.relativePath, $0) })

        let added = byPath["newFile.txt"]
        XCTAssertEqual(added?.kind, .added)
        XCTAssertEqual(added?.isDirectory, false)
        XCTAssertEqual(added?.beforeSize, 0)
        XCTAssertEqual(added?.afterSize, 250)
        XCTAssertEqual(added?.delta, 250)

        let removed = byPath["oldDir"]
        XCTAssertEqual(removed?.kind, .removed)
        XCTAssertEqual(removed?.isDirectory, true)
        XCTAssertEqual(removed?.beforeSize, 200)
        XCTAssertEqual(removed?.afterSize, 0)
        XCTAssertEqual(removed?.delta, -200)
        XCTAssertNil(byPath["oldDir/oldFile.txt"], "descendant of a removed directory must be collapsed into the directory's own row")

        let grew = byPath["sub/a.txt"]
        XCTAssertEqual(grew?.kind, .grew)
        XCTAssertEqual(grew?.beforeSize, 300)
        XCTAssertEqual(grew?.afterSize, 350)
        XCTAssertEqual(grew?.delta, 50)

        let shrank = byPath["big.bin"]
        XCTAssertEqual(shrank?.kind, .shrank)
        XCTAssertEqual(shrank?.beforeSize, 500)
        XCTAssertEqual(shrank?.afterSize, 100)
        XCTAssertEqual(shrank?.delta, -400)

        // Unchanged node must not appear at all.
        XCTAssertNil(byPath["sub/b.txt"])
        // The directory that merely contains a changed file must not be
        // reported itself (its size delta is implied by sub/a.txt's row).
        XCTAssertNil(byPath["sub"])
    }

    func test_compare_sorts_by_absolute_delta_descending() {
        let changes = ScanComparison.compare(before: makeBeforeTree(), after: makeAfterTree())
        let deltas = changes.map { abs($0.delta) }
        XCTAssertEqual(deltas, deltas.sorted(by: >))
        // big.bin (400) > newFile.txt (250) > oldDir (200) > sub/a.txt (50)
        XCTAssertEqual(changes.map(\.relativePath), ["big.bin", "newFile.txt", "oldDir", "sub/a.txt"])
    }

    func test_compare_identical_trees_reports_no_changes() {
        let tree = makeBeforeTree()
        XCTAssertTrue(ScanComparison.compare(before: tree, after: tree).isEmpty)
    }

    func test_compare_collapses_a_newly_added_directory_to_a_single_row() {
        // "before": just a root with one file.
        let beforeRoot = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 100, fileExtension: "", parent: nil)
        let keep = FSNode(url: URL(fileURLWithPath: "/scan/keep.txt"), name: "keep.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: beforeRoot)
        beforeRoot.children = [keep]
        let before = FileTreeBuilder.build(from: beforeRoot, rootPath: "/scan")

        // "after": same file, plus a whole new directory with two files inside.
        let afterRoot = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 400, fileExtension: "", parent: nil)
        let keep2 = FSNode(url: URL(fileURLWithPath: "/scan/keep.txt"), name: "keep.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: afterRoot)
        let newDir = FSNode(url: URL(fileURLWithPath: "/scan/newDir"), name: "newDir", isDirectory: true, size: 300, fileExtension: "", parent: afterRoot)
        let n1 = FSNode(url: URL(fileURLWithPath: "/scan/newDir/n1.txt"), name: "n1.txt", isDirectory: false, size: 200, fileExtension: "txt", parent: newDir)
        let n2 = FSNode(url: URL(fileURLWithPath: "/scan/newDir/n2.txt"), name: "n2.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: newDir)
        newDir.children = [n1, n2]
        afterRoot.children = [keep2, newDir]
        let after = FileTreeBuilder.build(from: afterRoot, rootPath: "/scan")

        let changes = ScanComparison.compare(before: before, after: after)
        XCTAssertEqual(changes.count, 1, "adding a whole directory tree must produce exactly one collapsed row")
        XCTAssertEqual(changes[0].relativePath, "newDir")
        XCTAssertEqual(changes[0].kind, .added)
        XCTAssertEqual(changes[0].afterSize, 300)
    }
}
