import AppKit
import SwiftUI

@MainActor
public final class ScanViewModel: ObservableObject {
    // The flat store the scanner hands back (see Sources/Model/). `root` is
    // a computed FileNode handle onto it, kept under the old name so views
    // that just read `vm.root` didn't need to change.
    @Published public var tree: FileTree?
    @Published public var cells: [TreemapCell] = []
    @Published public var colorMap: ExtensionColorMap?
    @Published public var selectedNode: FileNode?
    @Published public var isScanning: Bool = false
    @Published public var itemsScanned: Int = 0
    @Published public var bytesFound: Int64 = 0
    @Published public var errorMessage: String?
    @Published public var duplicatesReady: Bool = false
    @Published public var drillStack: [FileNode] = []
    @Published public var highlightedExtension: String?
    @Published public var isComputingLayout: Bool = false
    @Published public var scanURL: URL?
    @Published public var extensionSummaries: [ExtensionSummary] = []
    @Published public var duplicateGroups: [[FileNode]] = []
    @Published public var hasFullDiskAccess: Bool = true
    @Published public var isWatching: Bool = false
    @Published public var deniedCount: Int = 0
    @Published public var showFDASheet: Bool = false
    // Set when `tree` was loaded from a `.mdscan` archive instead of a live
    // scan: disables trash/delete actions and live FSEvents watching, and
    // drives the read-only banner in ContentView.
    @Published public var isReadOnlySnapshot: Bool = false
    @Published public var snapshotDate: Date?
    // Result of "Compare With Saved Scan…" (4c): diffing the currently
    // loaded tree against a `.mdscan` archive picked from disk. Entirely
    // separate from `isReadOnlySnapshot`/`tree` — comparing never replaces
    // the active tree, it only produces a side-by-side report.
    @Published public var comparisonResult: ComparisonResult?
    @Published public var isComputingComparison: Bool = false
    @Published public var showComparisonSheet: Bool = false

    public var root: FileNode? { tree.map { FileNode(tree: $0, index: $0.rootIndex) } }
    public var treemapRoot: FileNode? { drillStack.last ?? root }

    private let scanner = FileScanner()
    private let fileWatcher = FileWatcher()
    private var watchTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var extensionTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private var layoutDebounceTask: Task<Void, Never>?
    private var layoutSize: CGSize = .zero
    private var layoutGeneration: Int = 0
    private var securityScopedURL: URL?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var fdaSheetShownThisLaunch = false

    public init() {
        UserDefaults.standard.register(defaults: [
            "realtimeMonitoring": true,
            "autoScanLastFolder": false,
            "showHiddenFiles": false,
            "useBinarySize": false,
            "treemapColorScheme": "byType",
            "showFileCount": false,
            "excludedFolderNames": ".git,node_modules,DerivedData,.Trash",
            "defaultTab": "treemap",
        ])
        setupMemoryPressureHandler()
        checkFullDiskAccess()

        // A relaunch triggered from the Full Disk Access flow leaves behind the path
        // that was being scanned, so the new instance can resume right where the user
        // left off instead of landing back on the welcome screen.
        var resumedPendingRescan = false
        if let pending = UserDefaults.standard.string(forKey: "fdaPendingRescanPath") {
            UserDefaults.standard.removeObject(forKey: "fdaPendingRescanPath")
            if FileManager.default.fileExists(atPath: pending) {
                scan(url: URL(fileURLWithPath: pending))
                resumedPendingRescan = true
            }
        }

        if !resumedPendingRescan,
           UserDefaults.standard.bool(forKey: "autoScanLastFolder"),
           let path = UserDefaults.standard.string(forKey: "lastScannedPath"),
           FileManager.default.fileExists(atPath: path) {
            scan(url: URL(fileURLWithPath: path))
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    private func checkFullDiskAccess() {
        // TCC.db is only readable when Full Disk Access is granted
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: probe)
    }

    /// Public wrapper so the onboarding sheet can poll for a live permission change
    /// without exposing the private TCC probe itself.
    public func recheckFullDiskAccess() {
        checkFullDiskAccess()
    }

    /// Pure decision logic for whether the guided Full Disk Access sheet should be
    /// offered after a scan completes: only when access is actually missing, the scan
    /// hit blocked folders, and the user hasn't opted out.
    nonisolated static func shouldOfferFullDiskAccess(deniedCount: Int, hasFullDiskAccess: Bool, suppressed: Bool) -> Bool {
        !hasFullDiskAccess && deniedCount > 0 && !suppressed
    }

    /// Relaunches the app so macOS re-evaluates the Full Disk Access grant, and leaves
    /// a breadcrumb so the new instance automatically resumes the scan the user was on.
    public func relaunchForFullDiskAccess() {
        let pathToResume = scanURL?.path ?? UserDefaults.standard.string(forKey: "lastScannedPath")
        if let pathToResume {
            UserDefaults.standard.set(pathToResume, forKey: "fdaPendingRescanPath")
        }

        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            // Debug binary, not an app bundle — there's nothing to relaunch
            // programmatically. The developer restarts the process by hand.
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            // Give the new instance a moment to spawn before this one exits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        }
    }

    private func setupMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.isScanning else { return }
            self.cancelScan()
            self.errorMessage = "Scan cancelled: system memory is low."
        }
        source.resume()
        memoryPressureSource = source
    }

    public func scan(url: URL) {
        // Release any previous security scope before acquiring a new one
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil

        // App Sandbox: request access to the user-picked directory
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        scanTask?.cancel()
        extensionTask?.cancel()
        duplicateTask?.cancel()
        watchTask?.cancel()
        fileWatcher.stop()
        isWatching = false
        layoutGeneration += 1       // invalidate any in-progress layout
        scanURL = url
        UserDefaults.standard.set(url.path, forKey: "lastScannedPath")
        isReadOnlySnapshot = false
        snapshotDate = nil
        tree = nil
        cells = []
        colorMap = nil
        selectedNode = nil
        duplicatesReady = false
        highlightedExtension = nil
        drillStack = []
        extensionSummaries = []
        duplicateGroups = []
        isScanning = true
        itemsScanned = 0
        bytesFound = 0
        isComputingLayout = false
        errorMessage = nil
        deniedCount = 0

        scanTask = Task {
            for await progress in await scanner.scan(url: url) {
                switch progress {
                case .update(let items, let bytes):
                    self.itemsScanned = items
                    self.bytesFound = bytes
                case .completed(let scannedTree, let denied):
                    self.isScanning = false
                    self.deniedCount = denied
                    if !self.fdaSheetShownThisLaunch,
                       Self.shouldOfferFullDiskAccess(
                           deniedCount: denied,
                           hasFullDiskAccess: self.hasFullDiskAccess,
                           suppressed: UserDefaults.standard.bool(forKey: "fdaPromptSuppressed")
                       ) {
                        self.showFDASheet = true
                        self.fdaSheetShownThisLaunch = true
                    }
                    // If the scanned root is a volume mount point, the file total will
                    // always fall short of Finder's "used" figure (APFS snapshots,
                    // purgeable space, excluded/unreadable folders). Make that gap
                    // visible instead of silently under-reporting. Produces a NEW tree
                    // (topology is immutable) with the synthetic child already in its
                    // sorted place, so no separate sort pass is needed afterward.
                    let finalTree = Self.appendHiddenSpaceNodeIfNeeded(tree: scannedTree, scannedURL: url) ?? scannedTree
                    if ProcessInfo.processInfo.environment["MDS_DEBUG_TREE"] != nil {
                        let rootNode = FileNode(tree: finalTree, index: finalTree.rootIndex)
                        var dump = "TREE_COMPLETED total=\(rootNode.size) denied=\(denied)\n"
                        for c in rootNode.children.prefix(15) {
                            dump += "TREE_CHILD \(c.size) \(c.name)\(c.isSynthetic ? " [synthetic]" : "")\n"
                        }
                        FileHandle.standardError.write(dump.data(using: .utf8)!)
                    }
                    self.isComputingLayout = true   // keep spinner until treemap is ready
                    // Safety-tag the entire tree off-thread before exposing it to the UI.
                    // (Children are already size-sorted by FileTreeBuilder/the synthetic
                    // splice above, so unlike the old FSNode path there is no separate
                    // sort pass to run here.)
                    await Task.detached(priority: .userInitiated) {
                        Self.tagSafetyLevels(tree: finalTree)
                    }.value
                    self.tree = finalTree
                    let rootNode = FileNode(tree: finalTree, index: finalTree.rootIndex)
                    let map = ExtensionColorMap(root: rootNode)
                    self.colorMap = map
                    await self.recomputeLayout()
                    // isComputingLayout set to false inside recomputeLayout

                    // Start live file watching (if enabled)
                    if UserDefaults.standard.bool(forKey: "realtimeMonitoring") {
                        self.startWatching(url: url)
                    }

                    // Extension summaries: potentially millions of nodes — run off main actor
                    self.extensionTask = Task.detached(priority: .userInitiated) { [finalTree, map, weak self] in
                        let summaries = Self.buildExtensionSummaries(tree: finalTree, map: map)
                        guard !Task.isCancelled else { return }
                        let vm = self
                        await MainActor.run { vm?.extensionSummaries = summaries }
                    }
                    // Duplicate detection: lower priority, also off main actor
                    self.duplicateTask = Task.detached(priority: .utility) { [finalTree, weak self] in
                        let detector = DuplicateDetector()
                        await detector.detect(in: finalTree)
                        guard !Task.isCancelled else { return }
                        let groups = Self.buildDuplicateGroups(tree: finalTree)
                        guard !Task.isCancelled else { return }
                        let vm = self
                        await MainActor.run {
                            vm?.duplicatesReady = true
                            vm?.duplicateGroups = groups
                        }
                    }
                case .failed(let msg):
                    self.errorMessage = msg
                    self.isScanning = false
                    self.isComputingLayout = false
                }
            }
        }
    }

    public func cancelScan() {
        Task { await scanner.cancel() }
        scanTask?.cancel()
        extensionTask?.cancel()
        duplicateTask?.cancel()
        watchTask?.cancel()
        fileWatcher.stop()
        layoutGeneration += 1
        isScanning = false
        isComputingLayout = false
        isWatching = false
        scanURL = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Live watching

    private func startWatching(url: URL) {
        watchTask?.cancel()
        isWatching = false

        // Channel to bridge FileWatcher callback → async sequence
        let (stream, continuation) = AsyncStream<[String]>.makeStream()

        fileWatcher.start(watching: url) { paths in
            continuation.yield(paths)
        }
        isWatching = true

        watchTask = Task { [weak self] in
            for await changedPaths in stream {
                guard !Task.isCancelled else { break }
                await self?.handleFileSystemChanges(changedPaths)
            }
        }
    }

    // Incremental splice refresh: for each directory FSEvents reports as
    // changed, rescan just that directory from disk and splice the result
    // into `tree` (see `Self.splicedTree(afterChangeAt:in:)` /
    // `FileTree.replacingSubtree(at:with:)`) instead of rescanning the whole
    // root, exactly like the "Move to Trash" prune path already avoids a
    // full rescan for deletes. Multiple changed paths in one FSEvents batch
    // are folded sequentially — each splice's result feeds the next lookup —
    // which the plan explicitly allows as simpler than a single combined
    // multi-directory splice, at the cost of a little redundant rescanning
    // when a batch contains both a directory and one of its own descendants.
    //
    // Falls back to a full rescan (unchanged from before) only for the cases
    // a splice can't safely handle — see `splicedTree`'s doc comment: the
    // root itself changed/vanished, a changed path no longer resolves
    // anywhere in the tree, or it resolves into an auto-summarized node.
    // Not `private`: exercised directly by IncrementalRefreshTests (via
    // `@testable import`) to simulate an FSEvents batch deterministically,
    // without needing a real FSEventStream round trip.
    func handleFileSystemChanges(_ paths: [String]) async {
        guard let scanURL, let startingTree = tree, !isReadOnlySnapshot else { return }

        guard FileManager.default.fileExists(atPath: scanURL.path) else {
            // The scanned root itself is gone (deleted/renamed/unmounted) —
            // no subtree splice can recover from that.
            if ProcessInfo.processInfo.environment["MDS_DEBUG_TREE"] != nil {
                FileHandle.standardError.write("REFRESH fallback-full-rescan root-vanished root=\(scanURL.path)\n".data(using: .utf8)!)
            }
            scan(url: scanURL)
            return
        }

        var workingTree = startingTree
        for changedPath in paths {
            guard let spliced = Self.splicedTree(afterChangeAt: changedPath, in: workingTree) else {
                if ProcessInfo.processInfo.environment["MDS_DEBUG_TREE"] != nil {
                    FileHandle.standardError.write("REFRESH fallback-full-rescan path=\(changedPath)\n".data(using: .utf8)!)
                }
                scan(url: scanURL)
                return
            }
            workingTree = spliced
        }

        guard workingTree !== startingTree else { return } // nothing actually spliceable in this batch

        if ProcessInfo.processInfo.environment["MDS_DEBUG_TREE"] != nil {
            FileHandle.standardError.write("REFRESH spliced changedPaths=\(paths.count) root=\(scanURL.path)\n".data(using: .utf8)!)
        }
        await applySplicedTree(workingTree, from: startingTree)
    }

    // Rescans exactly the on-disk directory at `changedPath` (a full,
    // synchronous walk via `scanSubtree`, the same per-directory rescan step
    // the pre-Phase-2 refresh path used) and splices the result into `tree`,
    // replacing its stale subtree in place — the cheap alternative to
    // rescanning the whole root on every FSEvents notification.
    //
    // Returns nil when the splice can't be trusted, and the caller must fall
    // back to a full rescan of the root instead:
    //   - `changedPath` (after normalizing away a trailing slash) resolves
    //     to the tree's own root — a changed root might mean the scanned
    //     directory itself was replaced or renamed, which no subtree splice
    //     can recover from.
    //   - `changedPath` doesn't resolve to any node in `tree` at all: it (or
    //     an ancestor) was deleted/renamed since the last refresh, or it
    //     lives inside an auto-summarized directory, whose children were
    //     never materialized in the first place — the path-component walk
    //     simply runs out of children to match partway down.
    //   - the resolved node is itself auto-summarized: it has no children
    //     array to splice into (see AtomicDirectorySummary.swift) —
    //     re-summarizing it in place is future work; falling back to a full
    //     rescan is correct and simple for now.
    //   - the freshly-rescanned replacement contains a directory the real
    //     scanner's auto-summarization would have collapsed (named
    //     "node_modules", mirroring `knownGeneratedDirectoryNames` in
    //     AtomicDirectorySummary.swift) — `scanSubtree` below doesn't
    //     implement that heuristic at all, so materializing it here would
    //     both be slow and disagree with the rest of the tree's
    //     summarization policy.
    nonisolated static func splicedTree(afterChangeAt changedPath: String, in tree: FileTree) -> FileTree? {
        let normalized = (changedPath.hasSuffix("/") && changedPath != "/") ? String(changedPath.dropLast()) : changedPath

        guard var index = findIndex(forPath: normalized, in: tree) else { return nil }
        // FSEvents (without the FileEvents flag, which this app doesn't
        // request) reports directories, but be defensive: if this ever
        // resolves to a file, the directory that actually needs rescanning
        // is its parent.
        if !tree.records[index].isDirectory {
            let parent = tree.parentIndex[index]
            guard parent >= 0 else { return nil }
            index = parent
        }
        guard index != tree.rootIndex else { return nil }
        guard !tree.records[index].isAutoSummarized else { return nil }

        let node = FileNode(tree: tree, index: index)
        let showHiddenFiles = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        let excludedNames = parseExcludedNames()

        // Cross-tree hardlink dedup (BUG 2 fix): `scanSubtree`'s own
        // `treeRoot` parameter — meant to catch a hardlink whose twin lives
        // outside the directory being rescanned via `firstNode(withRef:in:)`
        // — only makes sense against a live FSNode tree, which no longer
        // exists on this flat-store splice path, so it stays `nil` below and
        // that check can never fire. Left alone, that means only hardlinks
        // *within* this one rescanned directory would get deduped (via the
        // fresh, otherwise-empty `seenRefs` below), and any twin living
        // outside the spliced subtree would double-count. Pre-seeding
        // `seenRefs` before the call replaces that dead check: it contains
        // every `hardLinkRef` that appears anywhere in `tree` OUTSIDE the
        // subtree being replaced, but ONLY when that outside occurrence is
        // itself the size carrier (size > 0). That asymmetry matters — if
        // the carrier instead lives INSIDE the subtree being replaced (i.e.
        // the outside twin is the 0-size loser), seeding on the twin's mere
        // presence would make the rescan zero its own copy too, and the
        // inode's bytes would vanish from the tree entirely (both copies at
        // 0) instead of correctly moving to whichever copy is now first-seen.
        var seenRefs = Self.hardLinkRefsOutsideSubtree(rootedAt: index, in: tree)

        // FIX 1 setup: capture which `hardLinkRef`s the OLD (stale) subtree
        // itself carried (size > 0), against the ORIGINAL tree, before it's
        // replaced below. This is the only place that information survives —
        // once `replacingSubtree` swaps the stale nodes out, there's no way
        // to tell "this ref isn't carried by the new subtree" apart from
        // "this ref was never carried by anything in this subtree at all".
        // See the comment at the promotion call site below for why this
        // matters: an external deletion (Finder/`rm`/a build tool — NOT this
        // app's own Trash action, which `FileTree.removingSubtrees` already
        // covers) of the carrier link inside this subtree leaves the inode
        // still fully allocated via a twin elsewhere, and nothing else in
        // this function would ever notice.
        let oldCarriedRefs = Self.carriedHardLinkRefs(insideSubtreeRootedAt: index, in: tree)

        let freshNode = scanSubtree(
            url: node.url,
            parent: nil,
            showHiddenFiles: showHiddenFiles,
            excludedNames: excludedNames,
            treeRoot: nil,
            seenRefs: &seenRefs
        )

        guard freshNode.name != "node_modules", !containsUnsummarizedGeneratedDirectory(freshNode) else { return nil }

        let subtree = FileTreeBuilder.build(from: freshNode, rootPath: node.url.path)
        var result = tree.replacingSubtree(at: index, with: subtree)

        // FIX 1: promote a surviving twin for every ref the OLD subtree
        // carried but the freshly-rescanned NEW subtree does not — the
        // on-disk link that carried the inode's bytes vanished for a reason
        // this splice can't otherwise account for (an external delete, not
        // this app's own Trash action). Without this, the bytes would simply
        // drop out of the tree until the next full rescan, even though the
        // inode is still fully allocated via a twin outside this subtree (or
        // even inside it — see `promotingSurvivingTwin`'s doc comment for why
        // a plain whole-tree search for the twin is correct either way).
        // Multiple independent orphaned refs (two unrelated hardlink pairs
        // both losing their carrier in the same splice) each promote their
        // own twin, one call per ref.
        if !oldCarriedRefs.isEmpty {
            var newCarriedRefs = Set<HardLinkRef>()
            for record in subtree.records where record.hardLinkRef != nil && record.size > 0 {
                newCarriedRefs.insert(record.hardLinkRef!)
            }
            for (ref, size) in oldCarriedRefs where !newCarriedRefs.contains(ref) {
                result = result.promotingSurvivingTwin(ref: ref, size: size)
            }
        }

        return result
    }

    // FIX 1 support for `splicedTree`: collects `hardLinkRef -> size` for
    // every node INSIDE the subtree rooted at `subtreeRootIndex` that is
    // itself the size carrier (`size > 0`) for its ref — the set of refs an
    // external deletion inside this subtree could orphan. Mirrors
    // `hardLinkRefsOutsideSubtree`'s traversal but walks IN rather than
    // computing the complement, and needs the size (not just the ref) so the
    // caller can promote a survivor to the exact right amount.
    private nonisolated static func carriedHardLinkRefs(insideSubtreeRootedAt subtreeRootIndex: Int, in tree: FileTree) -> [HardLinkRef: Int64] {
        var result: [HardLinkRef: Int64] = [:]
        var stack = [subtreeRootIndex]
        while let i = stack.popLast() {
            if let ref = tree.records[i].hardLinkRef, tree.records[i].size > 0 {
                result[ref] = tree.records[i].size
            }
            let start = tree.childStart[i]
            let cnt = tree.childCount[i]
            for offset in 0..<cnt {
                stack.append(tree.childIndices[start + offset])
            }
        }
        return result
    }

    // BUG 2 fix support for `splicedTree`: marks every node inside the
    // subtree rooted at `subtreeRootIndex` via the same iterative DFS
    // `FileTree.removingSubtrees`/`replacingSubtree` use, then collects every
    // `hardLinkRef` whose occurrence OUTSIDE that subtree is the size
    // carrier (`size > 0`). See the comment at the `splicedTree` call site
    // for why the `size > 0` condition (rather than mere presence) matters.
    private nonisolated static func hardLinkRefsOutsideSubtree(rootedAt subtreeRootIndex: Int, in tree: FileTree) -> Set<HardLinkRef> {
        let count = tree.records.count
        var inside = [Bool](repeating: false, count: count)
        var stack = [subtreeRootIndex]
        while let i = stack.popLast() {
            if inside[i] { continue }
            inside[i] = true
            let start = tree.childStart[i]
            let cnt = tree.childCount[i]
            for offset in 0..<cnt {
                stack.append(tree.childIndices[start + offset])
            }
        }

        var refs = Set<HardLinkRef>()
        for i in 0..<count where !inside[i] {
            if let ref = tree.records[i].hardLinkRef, tree.records[i].size > 0 {
                refs.insert(ref)
            }
        }
        return refs
    }

    // See the last bullet of `splicedTree`'s doc comment above.
    private nonisolated static func containsUnsummarizedGeneratedDirectory(_ node: FSNode) -> Bool {
        for child in node.children where child.isDirectory {
            if child.name == "node_modules" || containsUnsummarizedGeneratedDirectory(child) {
                return true
            }
        }
        return false
    }

    // Repairs everything that referenced the old topology after one or more
    // splices, mirroring `pruneTree(afterTrashing:from:)`: selection/drill
    // stack are captured as paths beforehand and resolved back to indices
    // afterward, since indices shift on every splice. The synthetic
    // "Hidden & Unreadable Space" root child is never touched by any splice
    // (it's a root-level child and a splice target is never the root — see
    // `splicedTree`'s root guard — so it always survives untouched, no
    // special-case re-appending needed here the way a full rescan needs
    // `appendHiddenSpaceNodeIfNeeded`).
    //
    // Unlike a prune, a splice can introduce brand-new nodes (the freshly
    // rescanned subtree), which start out `.caution`/no-duplicate-group from
    // `FileTreeBuilder` — same as any fresh scan — so safety tagging and
    // duplicate detection both re-run over the whole tree, exactly as they
    // do after `scan(url:)`. Safety tagging is awaited synchronously before
    // anything else touches `newTree.records`: it and `DuplicateDetector`
    // both mutate that array in place, so — same reasoning as `scan(url:)` —
    // they can't be allowed to run concurrently with each other.
    private func applySplicedTree(_ newTree: FileTree, from oldTree: FileTree) async {
        let selectedPath = selectedNode.map { oldTree.path(of: $0.index) }
        let drillPaths = drillStack.map { oldTree.path(of: $0.index) }

        await Task.detached(priority: .userInitiated) {
            Self.tagSafetyLevels(tree: newTree)
        }.value

        self.tree = newTree

        if let selectedPath, let idx = Self.findIndex(forPath: selectedPath, in: newTree) {
            selectedNode = FileNode(tree: newTree, index: idx)
        } else {
            selectedNode = nil
        }

        var newDrillStack: [FileNode] = []
        for path in drillPaths {
            guard let idx = Self.findIndex(forPath: path, in: newTree) else { break }
            newDrillStack.append(FileNode(tree: newTree, index: idx))
        }
        drillStack = newDrillStack

        let rootNode = FileNode(tree: newTree, index: newTree.rootIndex)
        let map = ExtensionColorMap(root: rootNode)
        colorMap = map

        extensionTask?.cancel()
        extensionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let summaries = Self.buildExtensionSummaries(tree: newTree, map: map)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.extensionSummaries = summaries }
        }

        duplicateTask?.cancel()
        duplicateTask = Task.detached(priority: .utility) { [weak self] in
            let detector = DuplicateDetector()
            await detector.detect(in: newTree)
            guard !Task.isCancelled else { return }
            let groups = Self.buildDuplicateGroups(tree: newTree)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.duplicatesReady = true
                self?.duplicateGroups = groups
            }
        }

        isComputingLayout = true
        await recomputeLayout()
    }

    // Walk the tree by path components to find the FSNode for a given path.
    private nonisolated static func findNode(path: String, in root: FSNode) -> FSNode? {
        let rootPath = root.url.path
        guard path.hasPrefix(rootPath) else { return nil }
        if path == rootPath { return root }

        let relative = String(path.dropFirst(rootPath.count))
        let components = relative.split(separator: "/").map(String.init)
        var current = root
        for component in components {
            guard let child = current.children.first(where: { $0.name == component }) else { return nil }
            current = child
        }
        return current
    }

    // Returns the allocated disk size (st_blocks * 512) for a path via lstat, or nil if
    // the path can't be stat'd or is a symlink.
    private nonisolated static func lstatInfo(path: String) -> (isDir: Bool, isSymlink: Bool, allocatedSize: Int64, linkCount: Int, ref: HardLinkRef)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let isSymlink = mode == S_IFLNK
        let isDir = mode == S_IFDIR
        let allocatedSize = Int64(st.st_blocks) * 512
        let ref = HardLinkRef(dev: UInt64(bitPattern: Int64(st.st_dev)), ino: UInt64(st.st_ino))
        return (isDir, isSymlink, allocatedSize, Int(st.st_nlink), ref)
    }

    // Climbs the parent chain to the tree's root node.
    private nonisolated static func rootNode(of node: FSNode) -> FSNode {
        var current = node
        while let parent = current.parent { current = parent }
        return current
    }

    // Iterative whole-tree search for a node representing the given inode.
    // Only invoked when hardlinked entries (st_nlink > 1) appear or disappear,
    // which is rare per refresh, so the O(tree) walk is acceptable.
    private nonisolated static func firstNode(withRef ref: HardLinkRef, in root: FSNode, requireZeroSize: Bool = false) -> FSNode? {
        var stack = [root]
        while let n = stack.popLast() {
            if n.hardLinkRef == ref, !requireZeroSize || n.size == 0 { return n }
            stack.append(contentsOf: n.children)
        }
        return nil
    }

    // Parses the excludedFolderNames default the same way FileScanner does.
    private nonisolated static func parseExcludedNames() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: "excludedFolderNames")
            ?? ".git,node_modules,DerivedData,.Trash"
        return Set(raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    // Re-stat the directory on disk and update children to match.
    // Returns true if anything changed (additions/removals/size changes).
    @discardableResult
    nonisolated static func refreshDirectory(node: FSNode) -> Bool {
        guard node.isDirectory else { return false }
        let fm = FileManager.default
        let showHiddenFiles = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        let excludedNames = parseExcludedNames()
        guard let entries = try? fm.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: nil,
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return false }

        // Filter out excluded folder names and symlinks up front, so both the
        // removal pass and the add/update pass agree on what's "on disk".
        var onDisk: [String: (url: URL, info: (isDir: Bool, isSymlink: Bool, allocatedSize: Int64, linkCount: Int, ref: HardLinkRef))] = [:]
        for url in entries {
            let name = url.lastPathComponent
            if excludedNames.contains(name) { continue }
            guard let info = lstatInfo(path: url.path) else { continue }
            if info.isSymlink { continue }
            onDisk[name] = (url, info)
        }

        var changed = false

        // Remove children that no longer exist on disk (or are now excluded/symlinks),
        // but never remove synthetic nodes (e.g. the "Hidden & Unreadable Space"
        // reconciliation entry), which never correspond to a real path.
        let removedSizeCarriers = node.children.filter {
            !$0.isSynthetic && !onDisk.keys.contains($0.name) && $0.hardLinkRef != nil && $0.size > 0
        }
        let before = node.children.count
        node.children.removeAll { !$0.isSynthetic && !onDisk.keys.contains($0.name) }
        if node.children.count != before { changed = true }

        // If a removed entry carried the representative size for a hardlinked inode
        // that still exists via other links, promote a surviving 0-size link
        // (anywhere in the tree) to carry the size, or the bytes vanish forever.
        for removed in removedSizeCarriers {
            guard let ref = removed.hardLinkRef else { continue }
            let root = rootNode(of: node)
            guard let survivor = firstNode(withRef: ref, in: root, requireZeroSize: true),
                  let survivorInfo = lstatInfo(path: survivor.url.path), !survivorInfo.isDir
            else { continue }
            survivor.size = survivorInfo.allocatedSize
            bubbleUpSizes(from: survivor.parent ?? survivor)
            changed = true
        }

        // Add or update children
        for (name, entry) in onDisk {
            let (url, info) = entry
            if let existing = node.children.first(where: { $0.name == name }) {
                // Update size for files (directories update via recursive bubble)
                if !existing.isDirectory {
                    if info.linkCount > 1 && existing.hardLinkRef == nil { existing.hardLinkRef = info.ref }
                    // A 0-byte node for a multi-link inode is a hardlink the initial scan
                    // already counted elsewhere — re-statting it would double-count.
                    if info.linkCount > 1 && existing.size == 0 { continue }
                    let newSize = info.allocatedSize
                    if existing.size != newSize {
                        existing.size = newSize
                        changed = true
                    }
                }
            } else if info.isDir {
                // New directory — scan its whole subtree so it isn't left as a 0-byte leaf.
                var seenRefs = Set<HardLinkRef>()
                let child = scanSubtree(url: url, parent: node, showHiddenFiles: showHiddenFiles, excludedNames: excludedNames, treeRoot: rootNode(of: node), seenRefs: &seenRefs)
                node.children.append(child)
                changed = true
            } else {
                // New file. A new name for an inode the tree already accounts for
                // (a hardlink created after the scan) must contribute 0 bytes.
                let ext = url.pathExtension.lowercased()
                var size = info.allocatedSize
                var linkRef: HardLinkRef?
                if info.linkCount > 1 {
                    linkRef = info.ref
                    if firstNode(withRef: info.ref, in: rootNode(of: node)) != nil { size = 0 }
                }
                let child = FSNode(url: url, name: name, isDirectory: false, size: size, fileExtension: ext, parent: node)
                child.hardLinkRef = linkRef
                child.safetyLevel = SafetyAnalyzer.level(for: child)
                node.children.append(child)
                changed = true
            }
        }

        if changed {
            node.children.sort { $0.size > $1.size }
        }
        return changed
    }

    // Synchronously walks a newly-discovered directory subtree, applying the same rules
    // as the initial scan: skip symlinks, skip hidden files unless showHiddenFiles, skip
    // excludedNames, allocated sizes via lstat, directory size = sum of children.
    private nonisolated static func scanSubtree(
        url: URL,
        parent: FSNode?,
        showHiddenFiles: Bool,
        excludedNames: Set<String>,
        treeRoot: FSNode?,
        seenRefs: inout Set<HardLinkRef>
    ) -> FSNode {
        let name = url.lastPathComponent
        guard let info = lstatInfo(path: url.path), info.isDir else {
            // Not actually a directory (or vanished) — return an empty leaf; caller only
            // invokes this when it already believes the entry is a directory.
            return FSNode(url: url, name: name, isDirectory: false, size: 0, fileExtension: url.pathExtension.lowercased(), parent: parent)
        }

        let node = FSNode(url: url, name: name, isDirectory: true, size: 0, fileExtension: "", parent: parent)
        node.safetyLevel = SafetyAnalyzer.level(for: node)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return node }

        var children: [FSNode] = []
        var totalSize: Int64 = 0
        for childURL in entries {
            let childName = childURL.lastPathComponent
            if excludedNames.contains(childName) { continue }
            guard let childInfo = lstatInfo(path: childURL.path) else { continue }
            if childInfo.isSymlink { continue }

            let child: FSNode
            if childInfo.isDir {
                child = scanSubtree(url: childURL, parent: node, showHiddenFiles: showHiddenFiles, excludedNames: excludedNames, treeRoot: treeRoot, seenRefs: &seenRefs)
            } else {
                let ext = childURL.pathExtension.lowercased()
                var size = childInfo.allocatedSize
                var linkRef: HardLinkRef?
                if childInfo.linkCount > 1 {
                    linkRef = childInfo.ref
                    if seenRefs.contains(childInfo.ref) {
                        size = 0
                    } else {
                        seenRefs.insert(childInfo.ref)
                        if let treeRoot, firstNode(withRef: childInfo.ref, in: treeRoot) != nil { size = 0 }
                    }
                }
                child = FSNode(url: childURL, name: childName, isDirectory: false, size: size, fileExtension: ext, parent: node)
                child.hardLinkRef = linkRef
                child.safetyLevel = SafetyAnalyzer.level(for: child)
            }
            children.append(child)
            totalSize += child.size
        }

        children.sort { $0.size > $1.size }
        node.children = children
        node.size = totalSize
        return node
    }

    // Computes the gap between what the volume reports as used (total - available)
    // and what the scanner actually accounted for. On APFS volumes this gap is
    // never zero: snapshots, purgeable space, and unreadable/excluded areas all
    // count toward "used" without ever appearing as a scannable file. Returns nil
    // when inputs are invalid or the gap is small enough to be measurement noise.
    nonisolated static func hiddenSpaceBytes(volumeTotal: Int64, volumeAvailable: Int64, scannedTotal: Int64) -> Int64? {
        guard volumeTotal > 0 else { return nil }
        let hidden = max(0, volumeTotal - volumeAvailable - scannedTotal)
        let oneGB: Int64 = 1_000_000_000
        return hidden >= oneGB ? hidden : nil
    }

    // When the scanned URL is itself a volume's mount point, returns a NEW
    // tree with a synthetic "Hidden & Unreadable Space" child representing
    // the portion of the volume's used space the scanner could never
    // account for (nil for non-volume scans, e.g. scanning a subfolder, or
    // when the gap is negligible). Topology is immutable on `FileTree`, so
    // this can't append in place the way the old FSNode version did.
    private nonisolated static func appendHiddenSpaceNodeIfNeeded(tree: FileTree, scannedURL: URL) -> FileTree? {
        guard let values = try? scannedURL.resourceValues(forKeys: [.volumeURLKey]),
              let volumeURL = values.volume,
              volumeURL.standardizedFileURL.path == scannedURL.standardizedFileURL.path
        else { return nil }

        guard let volumeValues = try? scannedURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let totalCapacity = volumeValues.volumeTotalCapacity,
              let availableCapacity = volumeValues.volumeAvailableCapacity
        else { return nil }

        guard let hidden = hiddenSpaceBytes(
            volumeTotal: Int64(totalCapacity),
            volumeAvailable: Int64(availableCapacity),
            scannedTotal: tree.records[tree.rootIndex].size
        ) else { return nil }

        return tree.appendingSyntheticRootChild(name: "Hidden & Unreadable Space", size: hidden)
    }

    // Walk up the parent chain recalculating folder sizes from their children.
    private nonisolated static func bubbleUpSizes(from node: FSNode) {
        var current: FSNode? = node
        while let n = current {
            if n.isDirectory {
                n.size = n.children.reduce(0) { $0 + $1.size }
            }
            current = n.parent
        }
    }

    public func updateLayoutSize(_ size: CGSize) {
        guard size != layoutSize, size.width > 1, size.height > 1 else { return }
        layoutSize = size
        // Debounce: skip intermediate sizes during animations/resize drags.
        // Only the last size in a burst triggers a layout computation.
        layoutDebounceTask?.cancel()
        layoutDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await recomputeLayout()
        }
    }

    public func drillDown(into node: FileNode) {
        guard node.isDirectory else { return }
        drillStack.append(node)
        Task { await recomputeLayout() }
    }

    public func drillUp() {
        guard !drillStack.isEmpty else { return }
        drillStack.removeLast()
        Task { await recomputeLayout() }
    }

    public func select(_ node: FileNode?) {
        selectedNode = node
    }

    public func highlight(extension ext: String?) {
        highlightedExtension = ext
    }

    public func refreshLayout() {
        guard let root else { return }
        colorMap = ExtensionColorMap(root: root)
        Task { await recomputeLayout() }
    }

    // MARK: - Move to Trash (prune-in-place, no rescan)

    // Moves a single node to the Trash and, if that succeeds, prunes it out
    // of the in-memory tree instead of triggering a full rescan. Returns
    // whether anything was actually trashed (mirrors the old call sites'
    // `try?`-and-check pattern).
    @discardableResult
    public func trashNode(_ node: FileNode) -> Bool {
        trashNodes([node])
    }

    // Moves several nodes to the Trash (the "keep 1, delete N" / "Delete All
    // Duplicates" case) and prunes every successfully-trashed one out of the
    // tree in a single splice, rather than rescanning once per node.
    //
    // An opened `.mdscan` archive is a read-only snapshot of a scan that may
    // no longer match what's on disk — trashing from it would either delete
    // the wrong (current, possibly since-changed) file or silently no-op,
    // neither of which is acceptable, so this is a hard no-op while a
    // snapshot is loaded.
    @discardableResult
    public func trashNodes(_ nodes: [FileNode]) -> Bool {
        guard !isReadOnlySnapshot, let currentTree = tree, !nodes.isEmpty else { return false }

        var trashedIndices: [Int] = []
        trashedIndices.reserveCapacity(nodes.count)
        for node in nodes where ObjectIdentifier(node.tree) == ObjectIdentifier(currentTree) {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                trashedIndices.append(node.index)
            } catch {
                // Swallow, same as the old per-call-site `try?` behavior —
                // one failed delete (e.g. permissions) shouldn't block the
                // rest of the batch or surface a blocking alert.
            }
        }
        guard !trashedIndices.isEmpty else { return false }

        pruneTree(afterTrashing: trashedIndices, from: currentTree)
        return true
    }

    // Splices the trashed nodes out of `tree` and repairs everything that
    // referenced the old topology: selection, drill stack, color map,
    // extension summaries, duplicate groups, and layout. Indices shift on
    // every prune, so selection/drill state is captured as paths beforehand
    // and resolved back to indices in the new tree afterward.
    private func pruneTree(afterTrashing indices: [Int], from oldTree: FileTree) {
        let selectedPath = selectedNode.map { oldTree.path(of: $0.index) }
        let drillPaths = drillStack.map { oldTree.path(of: $0.index) }

        let newTree = oldTree.removingSubtrees(at: indices)
        self.tree = newTree

        if let selectedPath, let idx = Self.findIndex(forPath: selectedPath, in: newTree) {
            selectedNode = FileNode(tree: newTree, index: idx)
        } else {
            selectedNode = nil
        }

        // Keep every prefix of the drill stack that still resolves; the
        // first missing entry (the trashed directory itself, if it was
        // drilled into) truncates the stack back to its nearest surviving
        // ancestor instead of leaving stale/dangling entries.
        var newDrillStack: [FileNode] = []
        for path in drillPaths {
            guard let idx = Self.findIndex(forPath: path, in: newTree) else { break }
            newDrillStack.append(FileNode(tree: newTree, index: idx))
        }
        drillStack = newDrillStack

        let rootNode = FileNode(tree: newTree, index: newTree.rootIndex)
        let map = ExtensionColorMap(root: rootNode)
        colorMap = map

        // Safety tags and duplicateGroupIDs are per-node fields that were
        // already computed on the surviving records and carry over as-is
        // through the splice (removingSubtrees copies whole `FileNodeRecord`
        // values), so only the two aggregate derived passes need to re-run —
        // and neither needs a full re-detect, just a re-group/re-bucket over
        // the pruned record set.
        extensionTask?.cancel()
        extensionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let summaries = Self.buildExtensionSummaries(tree: newTree, map: map)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.extensionSummaries = summaries }
        }

        duplicateTask?.cancel()
        duplicateTask = Task.detached(priority: .utility) { [weak self] in
            let groups = Self.buildDuplicateGroups(tree: newTree)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.duplicateGroups = groups }
        }

        Task { await recomputeLayout() }
    }

    // Resolves an absolute path back to an index in `tree` by walking
    // root->leaf name components (no full-tree path map to build — this is
    // only ever called for a handful of paths per prune: selection + drill
    // stack). Returns nil if the path no longer exists (it was the node
    // that got trashed, or a descendant of it).
    private nonisolated static func findIndex(forPath path: String, in tree: FileTree) -> Int? {
        if path == tree.rootPath { return tree.rootIndex }
        let rootPrefix = tree.rootPath.hasSuffix("/") ? tree.rootPath : tree.rootPath + "/"
        guard path.hasPrefix(rootPrefix) else { return nil }

        let relative = String(path.dropFirst(rootPrefix.count))
        let components = relative.split(separator: "/").map(String.init)
        var current = tree.rootIndex
        for component in components {
            let start = tree.childStart[current]
            let count = tree.childCount[current]
            guard let offset = (0..<count).first(where: { tree.records[tree.childIndices[start + $0]].name == component }) else {
                return nil
            }
            current = tree.childIndices[start + offset]
        }
        return current
    }

    // Whole-tree aggregate: a flat loop over `tree.records` reaches every
    // node without recursion, since the array already covers the entire
    // tree regardless of hierarchy.
    private nonisolated static func buildDuplicateGroups(tree: FileTree) -> [[FileNode]] {
        let all = (0..<tree.records.count).map { FileNode(tree: tree, index: $0) }
        let grouped = Dictionary(grouping: all.filter { $0.duplicateGroupID != nil }) { $0.duplicateGroupID! }
        return grouped.values
            .filter { $0.count > 1 }
            .sorted { lhs, rhs in
                let wastedLHS = lhs[0].size * Int64(lhs.count - 1)
                let wastedRHS = rhs[0].size * Int64(rhs.count - 1)
                return wastedLHS > wastedRHS
            }
    }

    public struct ExtensionSummary: Identifiable {
        public let id: String
        public let ext: String
        public let color: Color
        public let fileCount: Int
        public let totalSize: Int64
        public let percentage: Double
    }

    private nonisolated static func buildExtensionSummaries(tree: FileTree, map: ExtensionColorMap) -> [ExtensionSummary] {
        var groups: [String: (count: Int, size: Int64)] = [:]
        for record in tree.records where !record.isDirectory {
            groups[record.fileExtension, default: (0, 0)].count += 1
            groups[record.fileExtension, default: (0, 0)].size  += record.size
        }
        let total = Double(tree.records[tree.rootIndex].size)
        return groups.map { ext, stats in
            ExtensionSummary(
                id: ext,
                ext: ext.isEmpty ? "(directory)" : ".\(ext)",
                color: map.color(for: ext),
                fileCount: stats.count,
                totalSize: stats.size,
                percentage: total > 0 ? Double(stats.size) / total * 100 : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    private func recomputeLayout() async {
        guard let displayRoot = treemapRoot, let map = colorMap,
              layoutSize.width > 1, layoutSize.height > 1 else { return }
        layoutGeneration += 1
        let myGen = layoutGeneration
        isComputingLayout = true
        let rect = CGRect(origin: .zero, size: layoutSize)
        let computed = await Task.detached(priority: .userInitiated) {
            TreemapLayout.compute(root: displayRoot, in: rect, colorMap: map)
        }.value
        // Discard result if a newer layout was requested while we were computing
        guard myGen == layoutGeneration else { return }
        self.cells = computed
        self.isComputingLayout = false
    }

    // Flat loop over every index — order doesn't matter (each node's safety
    // level only depends on its own reconstructed path/name, both already
    // fully populated by the builder before this runs).
    private nonisolated static func tagSafetyLevels(tree: FileTree) {
        for index in 0..<tree.records.count {
            let node = FileNode(tree: tree, index: index)
            tree.setSafety(SafetyAnalyzer.level(for: node), at: index)
        }
    }

    // MARK: - Save / reopen scans (.mdscan archive)

    // Encodes the current tree + a small metadata block and writes it to
    // `url` off the main actor (encoding a multi-million-record tree to
    // JSON is real work). Errors surface through `errorMessage`, same as
    // `exportCSV`.
    public func saveScan(to url: URL) {
        guard let tree else { return }
        let metadata = ScanArchive.Metadata(
            scannedPath: tree.rootPath,
            scanDate: Date(),
            deniedCount: deniedCount,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )
        let archive = ScanArchive(tree: tree, metadata: metadata)

        Task.detached(priority: .utility) { [weak self] in
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(archive)
                try data.write(to: url, options: .atomic)
            } catch {
                await MainActor.run { self?.errorMessage = "Couldn't save scan: \(error.localizedDescription)" }
            }
        }
    }

    // Decodes and validates a `.mdscan` archive off the main actor, then
    // installs it as a read-only snapshot. A malformed or doctored archive
    // surfaces as `errorMessage` rather than crashing or hanging — see
    // `ScanArchive.validate()`.
    public func openArchive(from url: URL) {
        scanTask?.cancel()
        extensionTask?.cancel()
        duplicateTask?.cancel()
        watchTask?.cancel()
        fileWatcher.stop()
        isWatching = false
        layoutGeneration += 1
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        errorMessage = nil
        isScanning = true
        isComputingLayout = false

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let archive = try decoder.decode(ScanArchive.self, from: data)
                try archive.validate()
                let tree = archive.makeTree()
                await MainActor.run { self?.applyOpenedArchive(tree: tree, metadata: archive.metadata) }
            } catch {
                await MainActor.run {
                    self?.isScanning = false
                    self?.errorMessage = "Couldn't open scan: \(error.localizedDescription)"
                }
            }
        }
    }

    // Installs a validated, freshly-decoded tree as the active read-only
    // snapshot: no live watching is started (this never calls `scan(url:)`
    // or `startWatching`), and `isReadOnlySnapshot` gates trash actions off
    // for the rest of this tree's lifetime.
    private func applyOpenedArchive(tree: FileTree, metadata: ScanArchive.Metadata) {
        isScanning = false
        isReadOnlySnapshot = true
        snapshotDate = metadata.scanDate
        scanURL = URL(fileURLWithPath: metadata.scannedPath)
        deniedCount = metadata.deniedCount
        selectedNode = nil
        drillStack = []
        highlightedExtension = nil
        errorMessage = nil
        UserDefaults.standard.set(metadata.scannedPath, forKey: "lastScannedPath")

        self.tree = tree
        let rootNode = FileNode(tree: tree, index: tree.rootIndex)
        let map = ExtensionColorMap(root: rootNode)
        colorMap = map
        isComputingLayout = true
        Task { await recomputeLayout() }

        // Safety tags and duplicateGroupIDs were already computed before the
        // original scan was saved and travel with the archived records, so
        // only the two aggregate derived views need to be rebuilt.
        extensionTask?.cancel()
        extensionTask = Task.detached(priority: .userInitiated) { [tree, map, weak self] in
            let summaries = Self.buildExtensionSummaries(tree: tree, map: map)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.extensionSummaries = summaries }
        }

        duplicateGroups = Self.buildDuplicateGroups(tree: tree)
        duplicatesReady = true
    }

    // MARK: - Compare two scans (4c)

    // What `ComparisonView` renders: the diff itself plus enough context
    // about the "before" side (it was loaded from an archive, not the live
    // tree) to label the report meaningfully.
    public struct ComparisonResult: Sendable {
        public let changes: [ScanChange]
        public let beforeMetadata: ScanArchive.Metadata
        public let afterRootPath: String
    }

    // Loads `archiveURL` as the "before" snapshot and diffs it against the
    // currently active tree ("after"), off the main actor — decoding a large
    // archive and walking two multi-million-node trees is real work. Never
    // mutates `tree`/`isReadOnlySnapshot`: this is a read-only side report,
    // wholly independent of whatever is currently loaded/live-watched.
    public func compareWithSavedScan(archiveURL: URL) {
        guard let afterTree = tree else { return }
        errorMessage = nil
        isComputingComparison = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: archiveURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let archive = try decoder.decode(ScanArchive.self, from: data)
                try archive.validate()
                let beforeTree = archive.makeTree()
                let changes = ScanComparison.compare(before: beforeTree, after: afterTree)
                let result = ComparisonResult(changes: changes, beforeMetadata: archive.metadata, afterRootPath: afterTree.rootPath)
                await MainActor.run {
                    guard let self else { return }
                    self.comparisonResult = result
                    self.isComputingComparison = false
                    self.showComparisonSheet = true
                }
            } catch {
                await MainActor.run {
                    self?.isComputingComparison = false
                    self?.errorMessage = "Couldn't compare scan: \(error.localizedDescription)"
                }
            }
        }
    }

    public func exportCSV() {
        guard let tree else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(tree.records[tree.rootIndex].name)-disk-usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached(priority: .utility) { [tree] in
            var lines = ["Path,Size (bytes),Human Size,Type,Duplicate Group"]
            Self.appendCSV(tree: tree, to: &lines)
            let csv = lines.joined(separator: "\n") + "\n"
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private nonisolated static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private nonisolated static func appendCSV(tree: FileTree, to lines: inout [String]) {
        for index in 0..<tree.records.count {
            let record = tree.records[index]
            let type = record.isDirectory ? "directory" : record.fileExtension
            let group = record.duplicateGroupID?.uuidString ?? ""
            lines.append([
                csvEscape(tree.path(of: index)),
                "\(record.size)",
                csvEscape(ByteFormatter.string(from: record.size)),
                csvEscape(type),
                csvEscape(group)
            ].joined(separator: ","))
        }
    }
}
