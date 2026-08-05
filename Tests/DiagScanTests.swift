import XCTest
@testable import MacDirStat

// Diagnostic harness, not a CI test: scans a real directory with the production
// FileScanner and prints per-child totals for comparison against `du`.
// Enable with MDS_DIAG_PATH=/some/path.
final class DiagScanTests: XCTestCase {

    func test_diag_scan_prints_top_level_sizes() async throws {
        guard let target = ProcessInfo.processInfo.environment["MDS_DIAG_PATH"] else {
            throw XCTSkip("set MDS_DIAG_PATH to run the diagnostic scan")
        }

        let scanner = FileScanner()
        var completedRoot: FileNode?
        var lastItems = 0
        var lastBytes: Int64 = 0
        for await progress in await scanner.scan(url: URL(fileURLWithPath: target)) {
            switch progress {
            case .update(let items, let bytes):
                lastItems = items
                lastBytes = bytes
            case .completed(let tree, _):
                completedRoot = FileNode(tree: tree, index: tree.rootIndex)
            case .failed(let msg):
                XCTFail("scan failed: \(msg)")
            }
        }

        guard let root = completedRoot else {
            XCTFail("no completed root (last progress: \(lastItems) items, \(lastBytes) bytes)")
            return
        }

        func gb(_ v: Int64) -> String { String(format: "%.1f GB", Double(v) / 1_000_000_000) }
        print("DIAG root=\(target) total=\(gb(root.size)) rawBytes=\(root.size) progressBytes=\(gb(lastBytes)) items=\(lastItems)")
        for child in root.children.sorted(by: { $0.size > $1.size }).prefix(25) {
            print("DIAG child \(gb(child.size))  \(child.name)\(child.isDirectory ? "/" : "")")
        }
    }
}
