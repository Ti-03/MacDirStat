import XCTest
@testable import MacDirStat

final class ScanArchiveTests: XCTestCase {

    // Same shape as the FileTreeTests fixture:
    //   root (/scan)
    //     ├── big.bin (500)
    //     └── sub (dir)
    //          ├── a.txt (300)
    //          └── b.txt (100)
    private func makeFixtureTree() -> FileTree {
        let root = FSNode(url: URL(fileURLWithPath: "/scan"), name: "scan", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let big = FSNode(url: URL(fileURLWithPath: "/scan/big.bin"), name: "big.bin", isDirectory: false, size: 500, fileExtension: "bin", parent: root)
        big.hardLinkRef = HardLinkRef(dev: 1, ino: 42)
        let sub = FSNode(url: URL(fileURLWithPath: "/scan/sub"), name: "sub", isDirectory: true, size: 400, fileExtension: "", parent: root)
        let a = FSNode(url: URL(fileURLWithPath: "/scan/sub/a.txt"), name: "a.txt", isDirectory: false, size: 300, fileExtension: "txt", parent: sub)
        let b = FSNode(url: URL(fileURLWithPath: "/scan/sub/b.txt"), name: "b.txt", isDirectory: false, size: 100, fileExtension: "txt", parent: sub)
        sub.children = [a, b]
        root.children = [sub, big]
        root.size = big.size + sub.size

        let tree = FileTreeBuilder.build(from: root, rootPath: "/scan")
        // Give a couple of fields their post-scan-pass values so the round
        // trip test actually exercises non-default data.
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        let bigNode = rootNode.children.first { $0.name == "big.bin" }!
        let aNode = rootNode.children.first { $0.name == "sub" }!.children.first { $0.name == "a.txt" }!
        tree.setSafety(.danger, at: bigNode.index)
        let groupID = UUID()
        tree.setDuplicateGroupID(groupID, at: aNode.index)
        return tree
    }

    private func makeMetadata() -> ScanArchive.Metadata {
        ScanArchive.Metadata(scannedPath: "/scan", scanDate: Date(timeIntervalSince1970: 1_700_000_000), deniedCount: 3, appVersion: "1.1")
    }

    // MARK: - Round trip

    func test_round_trip_preserves_records_topology_and_sizes() throws {
        let tree = makeFixtureTree()
        let archive = ScanArchive(tree: tree, metadata: makeMetadata())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanArchive.self, from: data)
        try decoded.validate()

        XCTAssertEqual(decoded.records.count, tree.records.count)
        XCTAssertEqual(decoded.parentIndex, tree.parentIndex)
        XCTAssertEqual(decoded.childStart, tree.childStart)
        XCTAssertEqual(decoded.childCount, tree.childCount)
        XCTAssertEqual(decoded.childIndices, tree.childIndices)
        XCTAssertEqual(decoded.rootIndex, tree.rootIndex)
        XCTAssertEqual(decoded.rootPath, tree.rootPath)

        for i in 0..<tree.records.count {
            XCTAssertEqual(decoded.records[i].name, tree.records[i].name)
            XCTAssertEqual(decoded.records[i].size, tree.records[i].size)
            XCTAssertEqual(decoded.records[i].isDirectory, tree.records[i].isDirectory)
            XCTAssertEqual(decoded.records[i].safetyLevel, tree.records[i].safetyLevel)
            XCTAssertEqual(decoded.records[i].duplicateGroupID, tree.records[i].duplicateGroupID)
            XCTAssertEqual(decoded.records[i].hardLinkRef, tree.records[i].hardLinkRef)
        }
    }

    func test_make_tree_reconstructs_paths_identically() throws {
        let tree = makeFixtureTree()
        let archive = ScanArchive(tree: tree, metadata: makeMetadata())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanArchive.self, from: data)
        try decoded.validate()

        let restored = decoded.makeTree()
        for i in 0..<tree.records.count {
            XCTAssertEqual(restored.path(of: i), tree.path(of: i))
        }

        let rootNode = FileNode(tree: restored, index: restored.rootIndex)
        XCTAssertEqual(rootNode.children.map(\.name), ["big.bin", "sub"], "size-desc child order must survive the round trip")
    }

    func test_metadata_round_trips_including_format_version() throws {
        let tree = makeFixtureTree()
        let metadata = makeMetadata()
        let archive = ScanArchive(tree: tree, metadata: metadata)
        XCTAssertEqual(archive.metadata.formatVersion, ScanArchive.currentFormatVersion)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScanArchive.self, from: data)

        XCTAssertEqual(decoded.metadata.scannedPath, "/scan")
        XCTAssertEqual(decoded.metadata.deniedCount, 3)
        XCTAssertEqual(decoded.metadata.appVersion, "1.1")
        XCTAssertEqual(decoded.metadata.formatVersion, ScanArchive.currentFormatVersion)
        XCTAssertEqual(decoded.metadata.scanDate.timeIntervalSince1970, metadata.scanDate.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Validation: well-formed archive passes

    func test_validate_accepts_wellformed_archive() throws {
        let tree = makeFixtureTree()
        let archive = ScanArchive(tree: tree, metadata: makeMetadata())
        XCTAssertNoThrow(try archive.validate())
    }

    // MARK: - Validation: doctored archives are rejected

    func test_validate_rejects_out_of_range_child_index() {
        let tree = makeFixtureTree()
        var archive = ScanArchive(tree: tree, metadata: makeMetadata())
        var childIndices = archive.childIndices
        childIndices[0] = 9999 // clearly out of range
        archive = ScanArchive(
            records: archive.records, parentIndex: archive.parentIndex,
            childStart: archive.childStart, childCount: archive.childCount,
            childIndices: childIndices, rootIndex: archive.rootIndex,
            rootPath: archive.rootPath, metadata: archive.metadata
        )
        XCTAssertThrowsError(try archive.validate())
    }

    func test_validate_rejects_parent_cycle() {
        let tree = makeFixtureTree()
        let archive = ScanArchive(tree: tree, metadata: makeMetadata())
        // Introduce a cycle: make root's parent point at one of its own
        // descendants (the "sub" node), and register root as a child of
        // "sub" too, so the reachability walk from root either never
        // terminates cleanly or leaves the true root state inconsistent —
        // exercised by pointing rootIndex's own parentIndex at a non-root
        // node while keeping the reported rootIndex the same, which the
        // "root has a parent" check must catch.
        var parentIndex = archive.parentIndex
        let subIndex = archive.parentIndex.firstIndex(of: archive.rootIndex)! // first real child of root
        parentIndex[archive.rootIndex] = subIndex
        let doctored = ScanArchive(
            records: archive.records, parentIndex: parentIndex,
            childStart: archive.childStart, childCount: archive.childCount,
            childIndices: archive.childIndices, rootIndex: archive.rootIndex,
            rootPath: archive.rootPath, metadata: archive.metadata
        )
        XCTAssertThrowsError(try doctored.validate())
    }

    func test_validate_rejects_mismatched_array_lengths() {
        let tree = makeFixtureTree()
        let archive = ScanArchive(tree: tree, metadata: makeMetadata())
        let doctored = ScanArchive(
            records: archive.records, parentIndex: Array(archive.parentIndex.dropLast()),
            childStart: archive.childStart, childCount: archive.childCount,
            childIndices: archive.childIndices, rootIndex: archive.rootIndex,
            rootPath: archive.rootPath, metadata: archive.metadata
        )
        XCTAssertThrowsError(try doctored.validate())
    }

    func test_validate_rejects_unreachable_node() {
        let tree = makeFixtureTree()
        let archive = ScanArchive(tree: tree, metadata: makeMetadata())
        // Drop one entry from a parent's child span (shrink childCount) so
        // that node becomes unreachable from root, while everything else
        // (including its own parentIndex) stays as-is.
        var childCount = archive.childCount
        guard let parentWithChildren = (0..<childCount.count).first(where: { childCount[$0] > 0 }) else {
            return XCTFail("fixture must have at least one node with children")
        }
        childCount[parentWithChildren] -= 1
        let doctored = ScanArchive(
            records: archive.records, parentIndex: archive.parentIndex,
            childStart: archive.childStart, childCount: childCount,
            childIndices: archive.childIndices, rootIndex: archive.rootIndex,
            rootPath: archive.rootPath, metadata: archive.metadata
        )
        XCTAssertThrowsError(try doctored.validate())
    }

    func test_validate_rejects_empty_archive() {
        let archive = ScanArchive(
            records: [], parentIndex: [], childStart: [], childCount: [],
            childIndices: [], rootIndex: 0, rootPath: "/scan", metadata: makeMetadata()
        )
        XCTAssertThrowsError(try archive.validate())
    }
}

// Test-only initializer mirroring every stored property, so validation
// tests can construct a deliberately-doctored archive without going through
// `ScanArchive(tree:metadata:)`.
private extension ScanArchive {
    init(
        records: [FileNodeRecord], parentIndex: [Int], childStart: [Int],
        childCount: [Int], childIndices: [Int], rootIndex: Int,
        rootPath: String, metadata: ScanArchive.Metadata
    ) {
        self = try! JSONDecoder().decode(ScanArchive.self, from: JSONEncoder().encode(
            ScanArchiveTestPayload(
                records: records, parentIndex: parentIndex, childStart: childStart,
                childCount: childCount, childIndices: childIndices, rootIndex: rootIndex,
                rootPath: rootPath, metadata: metadata
            )
        ))
    }
}

// `ScanArchive`'s memberwise fields aren't independently settable (its only
// public initializer takes a `FileTree`), so this mirrors its `Codable`
// shape exactly and round-trips through JSON to construct arbitrary/doctored
// instances for the validator tests above.
private struct ScanArchiveTestPayload: Codable {
    let records: [FileNodeRecord]
    let parentIndex: [Int]
    let childStart: [Int]
    let childCount: [Int]
    let childIndices: [Int]
    let rootIndex: Int
    let rootPath: String
    let metadata: ScanArchive.Metadata
}
