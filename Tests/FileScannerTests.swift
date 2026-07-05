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

    // MARK: - Pinning tests for perf refactor (ScanConfig hoisting + TaskBudget fan-out cap)

    func test_scanner_respects_excluded_folder_names() async throws {
        let priorValue = UserDefaults.standard.string(forKey: "excludedFolderNames")
        UserDefaults.standard.set("skipme", forKey: "excludedFolderNames")
        defer {
            if let priorValue {
                UserDefaults.standard.set(priorValue, forKey: "excludedFolderNames")
            } else {
                UserDefaults.standard.removeObject(forKey: "excludedFolderNames")
            }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skipDir = tmp.appendingPathComponent("skipme")
        let keepDir = tmp.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: skipDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keepDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try Data(repeating: 0, count: 100 * 1024).write(to: skipDir.appendingPathComponent("big.bin"))
        try Data(repeating: 0, count: 4096).write(to: keepDir.appendingPathComponent("file.bin"))

        let scanner = FileScanner()
        var root: FSNode?
        for await progress in await scanner.scan(url: tmp) {
            if case .completed(let node) = progress { root = node }
        }

        XCTAssertNotNil(root)
        let names = Set(root?.children.map { $0.name } ?? [])
        XCTAssertFalse(names.contains("skipme"), "excluded folder should not appear as a child")
        XCTAssertTrue(names.contains("keep"))

        guard let keepNode = root?.children.first(where: { $0.name == "keep" }) else {
            return XCTFail("keep dir missing from scan results")
        }
        XCTAssertEqual(root?.size, keepNode.size, "root size should exclude the skipped folder's contents")
    }

    func test_scanner_honors_show_hidden_files_setting() async throws {
        let priorValue = UserDefaults.standard.object(forKey: "showHiddenFiles") as? Bool
        defer {
            if let priorValue {
                UserDefaults.standard.set(priorValue, forKey: "showHiddenFiles")
            } else {
                UserDefaults.standard.removeObject(forKey: "showHiddenFiles")
            }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(repeating: 0, count: 10).write(to: tmp.appendingPathComponent(".hidden"))
        try Data(repeating: 0, count: 10).write(to: tmp.appendingPathComponent("visible.txt"))

        UserDefaults.standard.set(false, forKey: "showHiddenFiles")
        do {
            let scanner = FileScanner()
            var root: FSNode?
            for await progress in await scanner.scan(url: tmp) {
                if case .completed(let node) = progress { root = node }
            }
            let names = Set(root?.children.map { $0.name } ?? [])
            XCTAssertFalse(names.contains(".hidden"), "hidden file should be excluded when showHiddenFiles is false")
            XCTAssertTrue(names.contains("visible.txt"))
        }

        UserDefaults.standard.set(true, forKey: "showHiddenFiles")
        do {
            let scanner = FileScanner()
            var root: FSNode?
            for await progress in await scanner.scan(url: tmp) {
                if case .completed(let node) = progress { root = node }
            }
            let names = Set(root?.children.map { $0.name } ?? [])
            XCTAssertTrue(names.contains(".hidden"), "hidden file should be included when showHiddenFiles is true")
            XCTAssertTrue(names.contains("visible.txt"))
        }
    }

    func test_scanner_handles_deep_wide_tree_correctly() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var allDirs: [URL] = []
        var allFiles: [URL] = []

        // Builds a tree nested 5 levels deep with ~40 directories total, each
        // holding exactly one 4 KB file. This stresses the bounded task-group
        // fan-out (Issue 2) to make sure totals stay correct regardless of
        // whether a subtree is scanned via the task group or inline recursion.
        let branchingPerLevel = [2, 2, 2, 2, 1]
        func buildLevel(base: URL, levelIndex: Int) throws {
            guard levelIndex < branchingPerLevel.count else { return }
            let branches = branchingPerLevel[levelIndex]
            for i in 0..<branches {
                let dir = base.appendingPathComponent("L\(levelIndex)_\(i)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                allDirs.append(dir)
                let file = dir.appendingPathComponent("file.bin")
                try Data(repeating: 0xAB, count: 4096).write(to: file)
                allFiles.append(file)
                try buildLevel(base: dir, levelIndex: levelIndex + 1)
            }
        }
        try buildLevel(base: tmp, levelIndex: 0)

        // Sanity check on the fixture itself.
        XCTAssertGreaterThanOrEqual(allDirs.count, 30)

        var expectedSize: Int64 = 0
        for fileURL in allFiles {
            var st = stat()
            XCTAssertEqual(lstat(fileURL.path, &st), 0)
            expectedSize += Int64(st.st_blocks) * 512
        }

        let scanner = FileScanner()
        var root: FSNode?
        for await progress in await scanner.scan(url: tmp) {
            if case .completed(let node) = progress { root = node }
        }

        XCTAssertNotNil(root)
        XCTAssertEqual(root?.size, expectedSize, "total allocated size must match regardless of task-group vs inline recursion")

        func countNodes(_ node: FSNode) -> (dirs: Int, files: Int) {
            if node.isDirectory {
                var dirs = 1
                var files = 0
                for child in node.children {
                    let c = countNodes(child)
                    dirs += c.dirs
                    files += c.files
                }
                return (dirs, files)
            } else {
                return (0, 1)
            }
        }

        let counts = countNodes(root!)
        XCTAssertEqual(counts.dirs, allDirs.count + 1, "every directory (plus root) must be reachable in the tree")
        XCTAssertEqual(counts.files, allFiles.count, "every file must be reachable in the tree")
    }
}
