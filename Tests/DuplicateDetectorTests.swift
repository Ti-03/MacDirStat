import XCTest
@testable import MacDirStat

final class DuplicateDetectorTests: XCTestCase {

    // Finds the record index for a given file name — the FSNode -> FileTree
    // conversion doesn't preserve any positional ordering guarantees the
    // tests can rely on, so tests look nodes up by name.
    private func index(in tree: FileTree, named name: String) -> Int? {
        tree.records.firstIndex { $0.name == name }
    }

    func test_detects_identical_files() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = Data(repeating: 42, count: 8192)
        let f1 = tmp.appendingPathComponent("copy1.bin")
        let f2 = tmp.appendingPathComponent("copy2.bin")
        let f3 = tmp.appendingPathComponent("unique.bin")
        try data.write(to: f1)
        try data.write(to: f2)
        try Data(repeating: 99, count: 8192).write(to: f3)

        let root = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for url in [f1, f2, f3] {
            let name = url.lastPathComponent
            let ext = url.pathExtension
            let child = FSNode(url: url, name: name, isDirectory: false, size: Int64(data.count), fileExtension: ext, parent: root)
            root.children.append(child)
            root.size += child.size
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)

        let detector = DuplicateDetector()
        if let groups = await detector.detect(in: tree) { tree.applyDuplicateGroups(groups) }

        let copy1 = index(in: tree, named: "copy1.bin")!
        let copy2 = index(in: tree, named: "copy2.bin")!
        let unique = index(in: tree, named: "unique.bin")!

        XCTAssertNotNil(tree.records[copy1].duplicateGroupID)
        XCTAssertNotNil(tree.records[copy2].duplicateGroupID)
        XCTAssertEqual(tree.records[copy1].duplicateGroupID, tree.records[copy2].duplicateGroupID)
        XCTAssertNil(tree.records[unique].duplicateGroupID, "unique file must not be grouped")
    }

    // Regression: `record.size` is the ALLOCATED size. Two sparse files that
    // share their first 64 KB, occupy the same few blocks on disk, but differ
    // in their tails were declared duplicates because the small-allocated-size
    // shortcut treated the 64 KB quick hash as a full-content hash.
    func test_sparse_files_with_same_head_and_different_tail_are_not_duplicates() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        func writeSparse(_ url: URL, tail: UInt8) throws {
            try Data(repeating: 7, count: 8192).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 4 * 1024 * 1024)
            try handle.write(contentsOf: Data([tail]))
        }
        let a = tmp.appendingPathComponent("a.bin")
        let b = tmp.appendingPathComponent("b.bin")
        let c = tmp.appendingPathComponent("c.bin")
        try writeSparse(a, tail: 1)
        try writeSparse(b, tail: 2)
        try writeSparse(c, tail: 1)   // genuinely identical to a

        // `size` in the tree is the ALLOCATED size the scanner records. Pin it
        // to what a sparse file occupies so the test does not depend on the
        // filesystem actually punching a hole: the point is that the detector
        // must not trust a small allocated size as "the quick hash saw it all".
        let root = FSNode(url: tmp, name: "root", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for url in [a, b, c] {
            let child = FSNode(url: url, name: url.lastPathComponent, isDirectory: false, size: 12_288, fileExtension: "bin", parent: root)
            root.children.append(child)
            root.size += child.size
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)
        if let groups = await DuplicateDetector().detect(in: tree) { tree.applyDuplicateGroups(groups) }

        let ia = index(in: tree, named: "a.bin")!, ib = index(in: tree, named: "b.bin")!, ic = index(in: tree, named: "c.bin")!
        XCTAssertNotNil(tree.records[ia].duplicateGroupID)
        XCTAssertEqual(tree.records[ia].duplicateGroupID, tree.records[ic].duplicateGroupID, "a and c are identical")
        XCTAssertNil(tree.records[ib].duplicateGroupID, "b differs in its tail and must not be grouped")
    }

    func test_small_files_below_threshold_are_skipped() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tinyData = Data(repeating: 1, count: 100) // below 4KB threshold
        let f1 = tmp.appendingPathComponent("tiny1.txt")
        let f2 = tmp.appendingPathComponent("tiny2.txt")
        try tinyData.write(to: f1)
        try tinyData.write(to: f2)

        let root = FSNode(url: tmp, name: "root", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for url in [f1, f2] {
            let child = FSNode(url: url, name: url.lastPathComponent, isDirectory: false, size: Int64(tinyData.count), fileExtension: "txt", parent: root)
            root.children.append(child)
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)

        let detector = DuplicateDetector()
        if let groups = await detector.detect(in: tree) { tree.applyDuplicateGroups(groups) }

        let tiny1 = index(in: tree, named: "tiny1.txt")!
        let tiny2 = index(in: tree, named: "tiny2.txt")!
        XCTAssertNil(tree.records[tiny1].duplicateGroupID, "files below threshold should not be grouped")
        XCTAssertNil(tree.records[tiny2].duplicateGroupID)
    }

    func test_same_prefix_different_tail_not_duplicates() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 128 KB files: identical first 64 KB (quick-hash prefix), different last bytes.
        let sharedPrefix = Data(repeating: 7, count: 65_536)
        let tail1 = Data(repeating: 1, count: 65_536)
        let tail2 = Data(repeating: 2, count: 65_536)
        let data1 = sharedPrefix + tail1
        let data2 = sharedPrefix + tail2

        let f1 = tmp.appendingPathComponent("a.bin")
        let f2 = tmp.appendingPathComponent("b.bin")
        try data1.write(to: f1)
        try data2.write(to: f2)

        let root = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for url in [f1, f2] {
            let child = FSNode(url: url, name: url.lastPathComponent, isDirectory: false, size: Int64(data1.count), fileExtension: "bin", parent: root)
            root.children.append(child)
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)

        let detector = DuplicateDetector()
        if let groups = await detector.detect(in: tree) { tree.applyDuplicateGroups(groups) }

        let a = index(in: tree, named: "a.bin")!
        let b = index(in: tree, named: "b.bin")!
        XCTAssertNil(tree.records[a].duplicateGroupID, "files sharing only a quick-hash prefix must not be grouped")
        XCTAssertNil(tree.records[b].duplicateGroupID)
    }

    func test_small_file_duplicates_detected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 8 KB files: above minSize (4 KB), below quickHashBytes (64 KB) -> quick hash IS full hash.
        let data = Data(repeating: 55, count: 8192)
        let other = Data(repeating: 66, count: 8192)
        let f1 = tmp.appendingPathComponent("s1.bin")
        let f2 = tmp.appendingPathComponent("s2.bin")
        let f3 = tmp.appendingPathComponent("s3.bin")
        try data.write(to: f1)
        try data.write(to: f2)
        try other.write(to: f3)

        let root = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for url in [f1, f2, f3] {
            let child = FSNode(url: url, name: url.lastPathComponent, isDirectory: false, size: Int64(data.count), fileExtension: "bin", parent: root)
            root.children.append(child)
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)

        let detector = DuplicateDetector()
        if let groups = await detector.detect(in: tree) { tree.applyDuplicateGroups(groups) }

        let s1 = index(in: tree, named: "s1.bin")!
        let s2 = index(in: tree, named: "s2.bin")!
        let s3 = index(in: tree, named: "s3.bin")!

        XCTAssertNotNil(tree.records[s1].duplicateGroupID)
        XCTAssertNotNil(tree.records[s2].duplicateGroupID)
        XCTAssertEqual(tree.records[s1].duplicateGroupID, tree.records[s2].duplicateGroupID)
        XCTAssertNil(tree.records[s3].duplicateGroupID)
    }

    func test_many_duplicate_pairs_all_detected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        let pairCount = 20
        var pairNames: [(String, String)] = []

        for i in 0..<pairCount {
            // Vary size (8-16 KB) and content per pair to avoid cross-pair collisions.
            let size = 8192 + (i * 1024) % 8192
            var bytes = [UInt8](repeating: 0, count: size)
            for j in 0..<size {
                bytes[j] = UInt8((i * 31 + j) % 256)
            }
            let data = Data(bytes)

            let fA = tmp.appendingPathComponent("pair\(i)_a.bin")
            let fB = tmp.appendingPathComponent("pair\(i)_b.bin")
            try data.write(to: fA)
            try data.write(to: fB)

            let childA = FSNode(url: fA, name: fA.lastPathComponent, isDirectory: false, size: Int64(size), fileExtension: "bin", parent: root)
            let childB = FSNode(url: fB, name: fB.lastPathComponent, isDirectory: false, size: Int64(size), fileExtension: "bin", parent: root)
            root.children.append(childA)
            root.children.append(childB)
            pairNames.append((fA.lastPathComponent, fB.lastPathComponent))
        }

        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)

        let detector = DuplicateDetector()
        if let groups = await detector.detect(in: tree) { tree.applyDuplicateGroups(groups) }

        var seenGroupIDs = Set<UUID>()
        for (nameA, nameB) in pairNames {
            let a = index(in: tree, named: nameA)!
            let b = index(in: tree, named: nameB)!
            XCTAssertNotNil(tree.records[a].duplicateGroupID, "\(nameA) should be grouped")
            XCTAssertNotNil(tree.records[b].duplicateGroupID, "\(nameB) should be grouped")
            XCTAssertEqual(tree.records[a].duplicateGroupID, tree.records[b].duplicateGroupID, "\(nameA) and \(nameB) should share a group")
            if let gid = tree.records[a].duplicateGroupID {
                XCTAssertFalse(seenGroupIDs.contains(gid), "group ID \(gid) reused across pairs")
                seenGroupIDs.insert(gid)
            }
        }
        XCTAssertEqual(seenGroupIDs.count, pairCount)
    }
}

final class DuplicateDetectorFocusTests: XCTestCase {
    func test_focus_only_examines_matching_size_buckets() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let small = Data(repeating: 5, count: 8192)
        let large = Data(repeating: 9, count: 16384)
        let files: [(String, Data)] = [("s1.bin", small), ("s2.bin", small), ("l1.bin", large), ("l2.bin", large)]
        let root = FSNode(url: tmp, name: "root", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for (name, data) in files {
            let url = tmp.appendingPathComponent(name)
            try data.write(to: url)
            root.children.append(FSNode(url: url, name: name, isDirectory: false, size: Int64(data.count), fileExtension: "bin", parent: root))
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: tmp.path)
        let idx = { (n: String) in tree.records.firstIndex { $0.name == n }! }

        // Focus on the small pair only: the large pair is never touched.
        let detected = await DuplicateDetector().detect(in: tree, focusing: [idx("s1.bin")])
        let result = try XCTUnwrap(detected)
        XCTAssertEqual(Set(result.keys), [idx("s1.bin"), idx("s2.bin")])
        XCTAssertNotNil(result[idx("s1.bin")]!)
        XCTAssertEqual(result[idx("s1.bin")]!, result[idx("s2.bin")]!)
    }
}
