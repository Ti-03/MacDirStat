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

    // Returns the (dev, ino) identity for a path the way the scanner records it.
    private func ref(at path: String) -> HardLinkRef {
        var st = stat()
        precondition(lstat(path, &st) == 0)
        return HardLinkRef(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
    }

    func test_refresh_new_hardlink_not_double_counted() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let orig = tmp.appendingPathComponent("orig.bin")
        try Data(repeating: 1, count: 262_144).write(to: orig)
        let fullSize = allocatedSize(at: orig.path)

        // Tree state as the initial scan left it: only orig.bin existed then.
        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: fullSize, fileExtension: "", parent: nil)
        let origNode = FSNode(url: orig, name: "orig.bin", isDirectory: false, size: fullSize, fileExtension: "bin", parent: dirNode)
        origNode.hardLinkRef = ref(at: orig.path)
        dirNode.children = [origNode]

        // A new hardlink appears after the scan.
        let newLink = tmp.appendingPathComponent("newlink.bin")
        try FileManager.default.linkItem(at: orig, to: newLink)

        ScanViewModel.refreshDirectory(node: dirNode)

        let linkNode = dirNode.children.first { $0.name == "newlink.bin" }
        XCTAssertNotNil(linkNode)
        XCTAssertEqual(linkNode?.size, 0, "a new name for an already-counted inode must not add size")
        XCTAssertNotNil(linkNode?.hardLinkRef)
        let total = dirNode.children.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(total, fullSize, "directory total must not double-count the inode")
    }

    func test_refresh_promotes_survivor_when_winner_deleted() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hard1 = tmp.appendingPathComponent("hard1.bin")
        let hard2 = tmp.appendingPathComponent("hard2.bin")
        let hard3 = tmp.appendingPathComponent("hard3.bin")
        try Data(repeating: 2, count: 262_144).write(to: hard1)
        try FileManager.default.linkItem(at: hard1, to: hard2)
        try FileManager.default.linkItem(at: hard1, to: hard3)
        let fullSize = allocatedSize(at: hard1.path)
        let inodeRef = ref(at: hard1.path)

        // Tree as the initial scan left it: hard1 carries the size, the others are 0.
        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: fullSize, fileExtension: "", parent: nil)
        let winner = FSNode(url: hard1, name: "hard1.bin", isDirectory: false, size: fullSize, fileExtension: "bin", parent: dirNode)
        let loser2 = FSNode(url: hard2, name: "hard2.bin", isDirectory: false, size: 0, fileExtension: "bin", parent: dirNode)
        let loser3 = FSNode(url: hard3, name: "hard3.bin", isDirectory: false, size: 0, fileExtension: "bin", parent: dirNode)
        for n in [winner, loser2, loser3] { n.hardLinkRef = inodeRef }
        dirNode.children = [winner, loser2, loser3]

        // The size-carrying link is deleted; the inode still exists via the survivors.
        try FileManager.default.removeItem(at: hard1)

        ScanViewModel.refreshDirectory(node: dirNode)

        XCTAssertEqual(dirNode.children.count, 2)
        let sizes = dirNode.children.map(\.size).sorted(by: >)
        XCTAssertEqual(sizes, [fullSize, 0], "one survivor must be promoted to carry the inode's size")
    }

    func test_scan_subtree_dedupes_internal_hardlinks() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Tree as scanned: empty directory.
        let dirNode = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        // A new directory appears containing two links to one inode.
        let newDir = tmp.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let a = newDir.appendingPathComponent("a.bin")
        try Data(repeating: 3, count: 262_144).write(to: a)
        try FileManager.default.linkItem(at: a, to: newDir.appendingPathComponent("b.bin"))
        let fullSize = allocatedSize(at: a.path)

        ScanViewModel.refreshDirectory(node: dirNode)

        let newDirNode = dirNode.children.first { $0.name == "newdir" }
        XCTAssertNotNil(newDirNode)
        XCTAssertEqual(newDirNode?.size, fullSize, "hardlinked pair inside a new directory must count once")
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
