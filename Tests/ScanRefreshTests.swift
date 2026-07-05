import XCTest
@testable import MacDirStat

final class ScanRefreshTests: XCTestCase {

    // Returns allocated disk size (st_blocks * 512) for a path, matching the scanner's metric.
    private func allocatedSize(at path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int64(st.st_blocks) * 512
    }

    func test_refresh_uses_allocated_size() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("a.bin")
        try Data([0x42]).write(to: fileURL)

        let expectedSize = allocatedSize(at: fileURL.path)
        XCTAssertGreaterThan(expectedSize, 0)

        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 999999, fileExtension: "", parent: nil)
        let staleChild = FSNode(url: fileURL, name: "a.bin", isDirectory: false, size: 999999, fileExtension: "bin", parent: dirNode)
        dirNode.children = [staleChild]

        ScanViewModel.refreshDirectory(node: dirNode)

        let updated = dirNode.children.first { $0.name == "a.bin" }
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.size, expectedSize, "refresh must use allocated size (st_blocks * 512), not logical size")
    }

    func test_refresh_preserves_hardlink_dedup() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hard1 = tmp.appendingPathComponent("hard1.bin")
        let hard2 = tmp.appendingPathComponent("hard2.bin")
        try Data(repeating: 1, count: 262_144).write(to: hard1)
        try FileManager.default.linkItem(at: hard1, to: hard2)
        let fullSize = allocatedSize(at: hard1.path)
        XCTAssertGreaterThan(fullSize, 0)

        // Initial scan counts a hardlinked inode once: hard1 keeps the size, hard2 is 0.
        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: fullSize, fileExtension: "", parent: nil)
        let winner = FSNode(url: hard1, name: "hard1.bin", isDirectory: false, size: fullSize, fileExtension: "bin", parent: dirNode)
        let loser = FSNode(url: hard2, name: "hard2.bin", isDirectory: false, size: 0, fileExtension: "bin", parent: dirNode)
        dirNode.children = [winner, loser]

        // Unrelated change in the same directory triggers a refresh.
        try Data(repeating: 9, count: 4096).write(to: tmp.appendingPathComponent("other.bin"))

        ScanViewModel.refreshDirectory(node: dirNode)

        let refreshedLoser = dirNode.children.first { $0.name == "hard2.bin" }
        let refreshedWinner = dirNode.children.first { $0.name == "hard1.bin" }
        XCTAssertEqual(refreshedLoser?.size, 0, "refresh must not resurrect a deduplicated hardlink to full size")
        XCTAssertEqual(refreshedWinner?.size, fullSize)
    }

    func test_refresh_scans_new_directory_recursively() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let newDir = tmp.appendingPathComponent("newdir")
        let subDir = newDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fileURL = subDir.appendingPathComponent("file.bin")
        try Data(repeating: 7, count: 8192).write(to: fileURL)

        let expectedFileSize = allocatedSize(at: fileURL.path)
        XCTAssertGreaterThan(expectedFileSize, 0)

        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        ScanViewModel.refreshDirectory(node: dirNode)

        let newDirNode = dirNode.children.first { $0.name == "newdir" }
        XCTAssertNotNil(newDirNode, "new directory should appear as a child")
        XCTAssertEqual(newDirNode?.isDirectory, true)
        XCTAssertEqual(newDirNode?.size, expectedFileSize, "new directory size should reflect the recursively-scanned subtree")

        let subDirNode = newDirNode?.children.first { $0.name == "sub" }
        XCTAssertNotNil(subDirNode, "nested subdirectory should be scanned")
        let fileNode = subDirNode?.children.first { $0.name == "file.bin" }
        XCTAssertNotNil(fileNode, "nested file should be present")
        XCTAssertEqual(fileNode?.size, expectedFileSize)
    }

    func test_refresh_skips_symlinks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let realURL = tmp.appendingPathComponent("real.bin")
        try Data(repeating: 1, count: 4096).write(to: realURL)
        let linkURL = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        ScanViewModel.refreshDirectory(node: dirNode)

        XCTAssertNil(dirNode.children.first { $0.name == "link" }, "symlinks must not be added by refresh")
        XCTAssertNotNil(dirNode.children.first { $0.name == "real.bin" })
    }

    func test_refresh_honors_hidden_files_setting() throws {
        let defaults = UserDefaults.standard
        let priorValue = defaults.object(forKey: "showHiddenFiles")
        defaults.set(true, forKey: "showHiddenFiles")
        defer {
            if let priorValue { defaults.set(priorValue, forKey: "showHiddenFiles") } else { defaults.removeObject(forKey: "showHiddenFiles") }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hiddenURL = tmp.appendingPathComponent(".dotfile")
        try Data(repeating: 3, count: 4096).write(to: hiddenURL)
        let expectedSize = allocatedSize(at: hiddenURL.path)

        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        ScanViewModel.refreshDirectory(node: dirNode)

        let hiddenChild = dirNode.children.first { $0.name == ".dotfile" }
        XCTAssertNotNil(hiddenChild, "when showHiddenFiles is true, refresh should include dotfiles")
        XCTAssertEqual(hiddenChild?.size, expectedSize)
    }

    func test_refresh_skips_excluded_folders() throws {
        let defaults = UserDefaults.standard
        let priorValue = defaults.object(forKey: "excludedFolderNames")
        defaults.set(".git,node_modules,DerivedData,.Trash", forKey: "excludedFolderNames")
        defer {
            if let priorValue { defaults.set(priorValue, forKey: "excludedFolderNames") } else { defaults.removeObject(forKey: "excludedFolderNames") }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let excludedDir = tmp.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: excludedDir, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 4096).write(to: excludedDir.appendingPathComponent("junk.bin"))

        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        ScanViewModel.refreshDirectory(node: dirNode)

        XCTAssertNil(dirNode.children.first { $0.name == "node_modules" }, "excluded folder names must not be added by refresh")
    }
}
