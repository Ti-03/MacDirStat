import XCTest
@testable import MacDirStat

@MainActor
final class HiddenSpaceTests: XCTestCase {

    // MARK: - hiddenSpaceBytes math

    func test_hidden_space_math() {
        // Simple case: 100 GB total, 40 GB available, 50 GB scanned -> 10 GB hidden
        let hundredGB: Int64 = 100_000_000_000
        let fortyGB: Int64 = 40_000_000_000
        let fiftyGB: Int64 = 50_000_000_000
        XCTAssertEqual(
            ScanViewModel.hiddenSpaceBytes(volumeTotal: hundredGB, volumeAvailable: fortyGB, scannedTotal: fiftyGB),
            10_000_000_000
        )
    }

    func test_hidden_space_below_1gb_is_nil() {
        // Gap is under 1 GB — treated as noise, not worth surfacing.
        let total: Int64 = 100_000_000_000
        let available: Int64 = 50_000_000_000
        let scanned: Int64 = 49_500_000_000 // gap = 500,000,000 (0.5 GB)
        XCTAssertNil(ScanViewModel.hiddenSpaceBytes(volumeTotal: total, volumeAvailable: available, scannedTotal: scanned))
    }

    func test_hidden_space_zero_total_is_nil() {
        XCTAssertNil(ScanViewModel.hiddenSpaceBytes(volumeTotal: 0, volumeAvailable: 0, scannedTotal: 0))
    }

    func test_hidden_space_negative_total_is_nil() {
        XCTAssertNil(ScanViewModel.hiddenSpaceBytes(volumeTotal: -1, volumeAvailable: 0, scannedTotal: 0))
    }

    func test_hidden_space_negative_gap_clamps_to_nil() {
        // scanned + available exceeds total (e.g. race/measurement skew) -> clamps to 0, below threshold -> nil
        let total: Int64 = 100_000_000_000
        let available: Int64 = 60_000_000_000
        let scanned: Int64 = 60_000_000_000
        XCTAssertNil(ScanViewModel.hiddenSpaceBytes(volumeTotal: total, volumeAvailable: available, scannedTotal: scanned))
    }

    // MARK: - refresh preserves synthetic children

    func test_refresh_preserves_synthetic_children() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let realFileURL = tmp.appendingPathComponent("real.bin")
        try Data(repeating: 0, count: 4096).write(to: realFileURL)

        let root = FSNode(url: tmp, name: tmp.lastPathComponent, isDirectory: true, size: 0, fileExtension: "", parent: nil)
        let realChild = FSNode(url: realFileURL, name: "real.bin", isDirectory: false, size: 4096, fileExtension: "bin", parent: root)

        let syntheticURL = tmp.appendingPathComponent("#hidden-space")
        let syntheticChild = FSNode(url: syntheticURL, name: "Hidden & Unreadable Space", isDirectory: false, size: 5_000_000_000, fileExtension: "", parent: root)
        syntheticChild.isSynthetic = true

        root.children = [realChild, syntheticChild]
        root.size = realChild.size + syntheticChild.size

        let changed = ScanViewModel.refreshDirectory(node: root)

        XCTAssertTrue(root.children.contains { $0.isSynthetic }, "synthetic child must survive a refresh pass")
        _ = changed
    }
}
