import XCTest
@testable import MacDirStat

final class DuplicateDetectorTests: XCTestCase {

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

        let detector = DuplicateDetector()
        await detector.detect(in: root)

        let copy1 = root.children.first { $0.name == "copy1.bin" }!
        let copy2 = root.children.first { $0.name == "copy2.bin" }!
        let unique = root.children.first { $0.name == "unique.bin" }!

        XCTAssertNotNil(copy1.duplicateGroupID)
        XCTAssertNotNil(copy2.duplicateGroupID)
        XCTAssertEqual(copy1.duplicateGroupID, copy2.duplicateGroupID)
        XCTAssertNil(unique.duplicateGroupID, "unique file must not be grouped")
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

        let detector = DuplicateDetector()
        await detector.detect(in: root)

        XCTAssertNil(root.children[0].duplicateGroupID, "files below threshold should not be grouped")
        XCTAssertNil(root.children[1].duplicateGroupID)
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

        let detector = DuplicateDetector()
        await detector.detect(in: root)

        XCTAssertNil(root.children[0].duplicateGroupID, "files sharing only a quick-hash prefix must not be grouped")
        XCTAssertNil(root.children[1].duplicateGroupID)
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

        let detector = DuplicateDetector()
        await detector.detect(in: root)

        let s1 = root.children.first { $0.name == "s1.bin" }!
        let s2 = root.children.first { $0.name == "s2.bin" }!
        let s3 = root.children.first { $0.name == "s3.bin" }!

        XCTAssertNotNil(s1.duplicateGroupID)
        XCTAssertNotNil(s2.duplicateGroupID)
        XCTAssertEqual(s1.duplicateGroupID, s2.duplicateGroupID)
        XCTAssertNil(s3.duplicateGroupID)
    }

    func test_many_duplicate_pairs_all_detected() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)

        let pairCount = 20
        var pairFiles: [[FSNode]] = []

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
            pairFiles.append([childA, childB])
        }

        let detector = DuplicateDetector()
        await detector.detect(in: root)

        var seenGroupIDs = Set<UUID>()
        for pair in pairFiles {
            let a = pair[0]
            let b = pair[1]
            XCTAssertNotNil(a.duplicateGroupID, "\(a.name) should be grouped")
            XCTAssertNotNil(b.duplicateGroupID, "\(b.name) should be grouped")
            XCTAssertEqual(a.duplicateGroupID, b.duplicateGroupID, "\(a.name) and \(b.name) should share a group")
            if let gid = a.duplicateGroupID {
                XCTAssertFalse(seenGroupIDs.contains(gid), "group ID \(gid) reused across pairs")
                seenGroupIDs.insert(gid)
            }
        }
        XCTAssertEqual(seenGroupIDs.count, pairCount)
    }
}
