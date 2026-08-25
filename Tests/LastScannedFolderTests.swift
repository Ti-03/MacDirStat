import XCTest
@testable import MacDirStat

/// The App Store build resumes the last scanned folder from a security-scoped
/// bookmark instead of a bare path. These cover the Developer ID branch, which
/// is what the test binary compiles as (`Build.isAppStore` is false here); the
/// bookmark branch needs a real sandbox to exercise.
final class LastScannedFolderTests: XCTestCase {

    private let pathKey = "lastScannedPath"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: ScanViewModel.lastScannedBookmarkKey)
        super.tearDown()
    }

    @MainActor
    func test_remembered_folder_resolves_back() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirstat-last-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        ScanViewModel.rememberLastScannedFolder(dir)

        XCTAssertEqual(ScanViewModel.resolveLastScannedFolder()?.path, dir.path)
    }

    @MainActor
    func test_folder_deleted_since_last_scan_resolves_to_nil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirstat-gone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        ScanViewModel.rememberLastScannedFolder(dir)
        try FileManager.default.removeItem(at: dir)

        // Auto-scan must not fire on a folder that no longer exists, or the app
        // opens onto an empty chart with no explanation.
        XCTAssertNil(ScanViewModel.resolveLastScannedFolder())
    }

    @MainActor
    func test_no_previous_scan_resolves_to_nil() {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: ScanViewModel.lastScannedBookmarkKey)

        XCTAssertNil(ScanViewModel.resolveLastScannedFolder())
    }
}
