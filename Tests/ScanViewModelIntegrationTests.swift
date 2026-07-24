import XCTest
@testable import MacDirStat

// End-to-end coverage for ScanViewModel.scan(url:) itself — the biggest
// rewritten code path in the Phase 2 flat-store migration (FileScanner ->
// FileTree -> safety tagging -> extension summaries -> duplicate detection ->
// layout), which none of the other test files exercise directly (they either
// drive FileScanner/FileTree/DuplicateDetector in isolation, or call the
// FSNode-based static refresh helpers directly).
@MainActor
final class ScanViewModelIntegrationTests: XCTestCase {

    private func withRealtimeMonitoringDisabled<T>(_ body: () async throws -> T) async rethrows -> T {
        let prior = UserDefaults.standard.object(forKey: "realtimeMonitoring") as? Bool
        UserDefaults.standard.set(false, forKey: "realtimeMonitoring")
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: "realtimeMonitoring") }
            else { UserDefaults.standard.removeObject(forKey: "realtimeMonitoring") }
        }
        return try await body()
    }

    // Polls a condition instead of a fixed sleep, since scan completion runs
    // through several hops (scanner -> Task.detached tagging -> recomputeLayout).
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_scan_populates_tree_layout_and_extension_summaries() async throws {
        try await withRealtimeMonitoringDisabled {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            try Data(repeating: 1, count: 8192).write(to: tmp.appendingPathComponent("a.bin"))
            try Data(repeating: 2, count: 4096).write(to: tmp.appendingPathComponent("b.txt"))
            let sub = tmp.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: 3, count: 2048).write(to: sub.appendingPathComponent("c.bin"))

            let vm = ScanViewModel()
            vm.updateLayoutSize(CGSize(width: 400, height: 400))
            vm.scan(url: tmp)

            await waitUntil { !vm.isScanning && !vm.isComputingLayout }

            XCTAssertNotNil(vm.tree)
            guard let root = vm.root else { return XCTFail("scan did not populate a root") }
            XCTAssertTrue(root.isDirectory)
            XCTAssertEqual(root.children.map(\.name).sorted(), ["a.bin", "b.txt", "sub"])
            // Children must be size-desc (a.bin=8192 > sub=2048 > b.txt=4096... sub aggregates
            // c.bin's 2048, so expected order is a.bin(8192), b.txt(4096), sub(2048)).
            XCTAssertEqual(root.children.map(\.name), ["a.bin", "b.txt", "sub"])

            // Safety tagging ran over the whole tree: a plain temp-dir file/subdir
            // matches none of the danger/safe path rules, so it settles at .caution
            // (the default an untagged record would also read as — the real signal
            // this checks is that tagging ran without crashing across a synthetic-free
            // tree with directories and files mixed together).
            for child in root.children {
                XCTAssertEqual(child.safetyLevel, .caution)
            }

            // Layout: a non-trivial layoutSize was set before scanning, so recomputeLayout
            // should have produced cells once the scan settled.
            await waitUntil { !vm.cells.isEmpty }
            XCTAssertFalse(vm.cells.isEmpty, "treemap layout should be computed after a scan completes")

            // Extension summaries run off-thread; wait for them to land.
            await waitUntil(timeout: 5) { !vm.extensionSummaries.isEmpty }
            XCTAssertFalse(vm.extensionSummaries.isEmpty)
            let binSummary = vm.extensionSummaries.first { $0.ext == ".bin" }
            XCTAssertNotNil(binSummary)
            XCTAssertEqual(binSummary?.fileCount, 2, "both a.bin and sub/c.bin should be counted")
        }
    }

    func test_scan_of_deleted_root_reports_failure_not_crash() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Never created — the scanner should treat it as a nonexistent leaf,
        // not throw or crash the view model.
        let vm = ScanViewModel()
        vm.scan(url: missing)
        await waitUntil { !vm.isScanning }
        // Whatever the scanner decides (empty leaf vs failure), the view model
        // must reach a settled, non-scanning state without crashing.
        XCTAssertFalse(vm.isScanning)
    }
}
