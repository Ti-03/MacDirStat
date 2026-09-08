import XCTest
@testable import MacDirStat

// Regression: with factory defaults (no user-set exclusions, no hidden-file
// setting), a scan must account for EVERY byte under the root. The shipped
// 1.3 defaults excluded `.git,node_modules,DerivedData,.Trash` and skipped
// dotfiles, which made a real 7.3 GB project report as 40 MB.
final class DefaultScanCoverageTests: XCTestCase {

    private let keys = ["excludedFolderNames", "showHiddenFiles", "autoSummarizeEnabled"]

    private func withFactoryDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
        let prior = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        defer {
            for (key, value) in prior {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        return try await body()
    }

    private func write(_ bytes: Int, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func allocated(_ url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return Int64(st.st_blocks) * 512
    }

    private func scanTree(at url: URL) async -> FileNode? {
        let scanner = FileScanner()
        var root: FileNode?
        for await progress in await scanner.scan(url: url) {
            if case .completed(let tree, _) = progress { root = FileNode(tree: tree, index: tree.rootIndex) }
        }
        return root
    }

    func test_factory_defaults_account_for_every_byte() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mds-default-coverage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let files: [(String, Int)] = [
            ("src/main.swift", 20_000),
            (".git/objects/ab/cdef", 300_000),
            (".hidden-cache/blob", 150_000),
            ("node_modules/pkg/dist/index.js", 400_000),
            ("DerivedData/Build/app.bin", 900_000),
            (".Trash/old.dmg", 250_000),
            (".DS_Store", 6_000),
        ]
        var expected: Int64 = 0
        for (relative, bytes) in files {
            let url = dir.appendingPathComponent(relative)
            try write(bytes, at: url)
            expected += allocated(url)
        }

        let root = await withFactoryDefaults { await scanTree(at: dir) }
        let unwrapped = try XCTUnwrap(root)

        XCTAssertEqual(unwrapped.size, expected, "scan under factory defaults must equal the sum of every file's allocated size")

        let names = Set(unwrapped.children.map(\.name))
        for name in [".git", ".hidden-cache", "node_modules", "DerivedData", ".Trash", ".DS_Store", "src"] {
            XCTAssertTrue(names.contains(name), "\(name) missing from root children: \(names.sorted())")
        }

        // Generated trees are collapsed into one browsable-as-a-whole node,
        // never silently dropped.
        let nodeModules = try XCTUnwrap(unwrapped.children.first { $0.name == "node_modules" })
        XCTAssertTrue(nodeModules.isAutoSummarized)
        XCTAssertEqual(nodeModules.descendantFileCount, 1)
        let git = try XCTUnwrap(unwrapped.children.first { $0.name == ".git" })
        XCTAssertTrue(git.isAutoSummarized)
    }

    func test_symlinked_root_scans_its_target() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mds-symroot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try write(50_000, at: real.appendingPathComponent("a.bin"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let scanned = await scanTree(at: link)
        let root = try XCTUnwrap(scanned)
        XCTAssertEqual(root.size, allocated(real.appendingPathComponent("a.bin")))
        XCTAssertEqual(root.children.map(\.name), ["a.bin"])
        XCTAssertEqual(root.tree.rootPath, FileScanner.resolvingSymlinkRoot(link).path)
    }

    func test_legacy_exclusion_default_is_reset_once() {
        let suite = "mds-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(".git,node_modules,DerivedData,.Trash", forKey: "excludedFolderNames")
        ScanViewModel.migrateLegacyExclusionDefault(in: defaults)
        XCTAssertNil(defaults.string(forKey: "excludedFolderNames"), "legacy factory value is reset")

        defaults.set(".git,node_modules,DerivedData,.Trash", forKey: "excludedFolderNames")
        ScanViewModel.migrateLegacyExclusionDefault(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "excludedFolderNames"), ".git,node_modules,DerivedData,.Trash", "runs only once")

        let custom = UserDefaults(suiteName: suite + "-custom")!
        defer { custom.removePersistentDomain(forName: suite + "-custom") }
        custom.set("Library,Movies", forKey: "excludedFolderNames")
        ScanViewModel.migrateLegacyExclusionDefault(in: custom)
        XCTAssertEqual(custom.string(forKey: "excludedFolderNames"), "Library,Movies", "user customisation is preserved")
    }

    func test_shared_defaults_are_used_everywhere() {
        XCTAssertEqual(ScanDefaults.excludedFolderNames, "")
        XCTAssertTrue(ScanDefaults.showHiddenFiles)
        XCTAssertTrue(knownGeneratedDirectoryNames.isSuperset(of: ["node_modules", ".git", "Pods", ".next"]))
    }
}
