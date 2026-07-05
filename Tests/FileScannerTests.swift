import XCTest
@testable import MacDirStat

final class FileScannerTests: XCTestCase {

    func test_fsnode_file_stores_properties() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        let node = FSNode(url: url, name: "test.pdf", isDirectory: false, size: 1024, fileExtension: "pdf", parent: nil)
        XCTAssertEqual(node.name, "test.pdf")
        XCTAssertEqual(node.size, 1024)
        XCTAssertEqual(node.fileExtension, "pdf")
        XCTAssertFalse(node.isDirectory)
        XCTAssertNil(node.parent)
    }

    func test_fsnode_directory_accumulates_children_size() {
        let dir = FSNode(url: URL(fileURLWithPath: "/tmp"), name: "tmp", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let child1 = FSNode(url: URL(fileURLWithPath: "/tmp/a"), name: "a", isDirectory: false, size: 500, fileExtension: "txt", parent: dir)
        let child2 = FSNode(url: URL(fileURLWithPath: "/tmp/b"), name: "b", isDirectory: false, size: 300, fileExtension: "jpg", parent: dir)
        dir.children = [child1, child2]
        dir.size = child1.size + child2.size
        XCTAssertEqual(dir.size, 800)
        XCTAssertEqual(dir.children.count, 2)
        XCTAssertTrue(dir.children[0].parent === dir)
    }

    func test_fsnode_parent_reference_is_weak() {
        var dir: FSNode? = FSNode(url: URL(fileURLWithPath: "/tmp"), name: "tmp", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let child = FSNode(url: URL(fileURLWithPath: "/tmp/a"), name: "a", isDirectory: false, size: 100, fileExtension: "txt", parent: dir)
        dir = nil
        XCTAssertNil(child.parent)
    }

    func test_optional_children_returns_all_children() {
        let dir = FSNode(url: URL(fileURLWithPath: "/tmp"), name: "tmp", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for i in 0..<2001 {
            let child = FSNode(url: URL(fileURLWithPath: "/tmp/\(i)"), name: "\(i)", isDirectory: false, size: 1, fileExtension: "txt", parent: dir)
            dir.children.append(child)
        }
        XCTAssertEqual(dir.optionalChildren?.count, 2001)
    }

    func test_scanner_builds_tree_from_temp_directory() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file1 = tmp.appendingPathComponent("hello.txt")
        let file2 = tmp.appendingPathComponent("world.pdf")
        try "Hello".data(using: .utf8)!.write(to: file1)
        try Data(repeating: 0, count: 2048).write(to: file2)

        let scanner = FileScanner()
        var root: FSNode?
        for await progress in await scanner.scan(url: tmp) {
            if case .completed(let node) = progress { root = node }
        }

        XCTAssertNotNil(root)
        XCTAssertTrue(root!.isDirectory)
        XCTAssertEqual(root!.children.count, 2)
        XCTAssertGreaterThan(root!.size, 0)
        let names = Set(root!.children.map { $0.name })
        XCTAssertTrue(names.contains("hello.txt"))
        XCTAssertTrue(names.contains("world.pdf"))
    }

    func test_scanner_rolls_up_directory_size() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data(repeating: 0, count: 4096).write(to: sub.appendingPathComponent("big.bin"))

        let scanner = FileScanner()
        var root: FSNode?
        for await progress in await scanner.scan(url: tmp) {
            if case .completed(let node) = progress { root = node }
        }

        XCTAssertEqual(root?.size ?? 0, root?.children.first?.size ?? -1)
    }

    func test_scanner_skips_symlinks() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let real = tmp.appendingPathComponent("real.txt")
        try "data".data(using: .utf8)!.write(to: real)
        let link = tmp.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let scanner = FileScanner()
        var root: FSNode?
        for await progress in await scanner.scan(url: tmp) {
            if case .completed(let node) = progress { root = node }
        }

        XCTAssertEqual(root?.children.count, 1, "symlink should be skipped")
        XCTAssertEqual(root?.children.first?.name, "real.txt")
    }
}
