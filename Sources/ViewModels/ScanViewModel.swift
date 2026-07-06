import AppKit
import SwiftUI

@MainActor
public final class ScanViewModel: ObservableObject {
    @Published public var root: FSNode?
    @Published public var cells: [TreemapCell] = []
    @Published public var colorMap: ExtensionColorMap?
    @Published public var selectedNode: FSNode?
    @Published public var isScanning: Bool = false
    @Published public var itemsScanned: Int = 0
    @Published public var bytesFound: Int64 = 0
    @Published public var errorMessage: String?
    @Published public var duplicatesReady: Bool = false
    @Published public var drillStack: [FSNode] = []
    @Published public var highlightedExtension: String?
    @Published public var isComputingLayout: Bool = false
    @Published public var scanURL: URL?
    @Published public var extensionSummaries: [ExtensionSummary] = []
    @Published public var duplicateGroups: [[FSNode]] = []
    @Published public var hasFullDiskAccess: Bool = true
    @Published public var isWatching: Bool = false

    public var treemapRoot: FSNode? { drillStack.last ?? root }

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
        if UserDefaults.standard.bool(forKey: "autoScanLastFolder"),
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
        root = nil
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

        scanTask = Task {
            for await progress in await scanner.scan(url: url) {
                switch progress {
                case .update(let items, let bytes):
                    self.itemsScanned = items
                    self.bytesFound = bytes
                case .completed(let node):
                    if ProcessInfo.processInfo.environment["MDS_DEBUG_TREE"] != nil {
                        var dump = "TREE_COMPLETED total=\(node.size)\n"
                        for c in node.children.sorted(by: { $0.size > $1.size }).prefix(15) {
                            dump += "TREE_CHILD \(c.size) \(c.name)\n"
                        }
                        FileHandle.standardError.write(dump.data(using: .utf8)!)
                    }
                    self.isScanning = false
                    self.isComputingLayout = true   // keep spinner until treemap is ready
                    // Sort + safety-tag the entire tree off-thread before exposing it to the UI.
                    await Task.detached(priority: .userInitiated) {
                        Self.sortAllChildren(node: node)
                        Self.tagSafetyLevels(node: node)
                    }.value
                    self.root = node
                    let map = ExtensionColorMap(root: node)
                    self.colorMap = map
                    await self.recomputeLayout()
                    // isComputingLayout set to false inside recomputeLayout

                    // Start live file watching (if enabled)
                    if UserDefaults.standard.bool(forKey: "realtimeMonitoring") {
                        self.startWatching(url: url)
                    }

                    // Extension summaries: potentially millions of nodes — run off main actor
                    self.extensionTask = Task.detached(priority: .userInitiated) { [node, map, weak self] in
                        let summaries = Self.buildExtensionSummaries(root: node, map: map)
                        guard !Task.isCancelled else { return }
                        let vm = self
                        await MainActor.run { vm?.extensionSummaries = summaries }
                    }
                    // Duplicate detection: lower priority, also off main actor
                    self.duplicateTask = Task.detached(priority: .utility) { [node, weak self] in
                        let detector = DuplicateDetector()
                        await detector.detect(in: node)
                        guard !Task.isCancelled else { return }
                        let groups = Self.buildDuplicateGroups(root: node)
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

    private func handleFileSystemChanges(_ paths: [String]) async {
        guard let root else { return }

        // Collect the unique directory paths that changed
        var dirPaths = Set<String>()
        for path in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                dirPaths.insert(path)
            } else {
                dirPaths.insert((path as NSString).deletingLastPathComponent)
            }
        }

        var needsLayout = false
        for dirPath in dirPaths {
            guard let node = Self.findNode(path: dirPath, in: root) else { continue }
            let sizeBefore = node.size
            let changed = await Task.detached(priority: .userInitiated) {
                Self.refreshDirectory(node: node)
            }.value
            if changed {
                Self.bubbleUpSizes(from: node)
                needsLayout = true
            }
            if ProcessInfo.processInfo.environment["MDS_DEBUG_TREE"] != nil {
                let line = "REFRESH changed=\(changed) nodeBefore=\(sizeBefore) nodeAfter=\(node.size) rootAfter=\(root.size) path=\(dirPath)\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
        }

        if needsLayout {
            await recomputeLayout()
        }
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
    private nonisolated static func lstatInfo(path: String) -> (isDir: Bool, isSymlink: Bool, allocatedSize: Int64, linkCount: Int)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let isSymlink = mode == S_IFLNK
        let isDir = mode == S_IFDIR
        let allocatedSize = Int64(st.st_blocks) * 512
        return (isDir, isSymlink, allocatedSize, Int(st.st_nlink))
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
        var onDisk: [String: (url: URL, info: (isDir: Bool, isSymlink: Bool, allocatedSize: Int64, linkCount: Int))] = [:]
        for url in entries {
            let name = url.lastPathComponent
            if excludedNames.contains(name) { continue }
            guard let info = lstatInfo(path: url.path) else { continue }
            if info.isSymlink { continue }
            onDisk[name] = (url, info)
        }

        var changed = false

        // Remove children that no longer exist (or are now excluded/symlinks)
        let before = node.children.count
        node.children.removeAll { !onDisk.keys.contains($0.name) }
        if node.children.count != before { changed = true }

        // Add or update children
        for (name, entry) in onDisk {
            let (url, info) = entry
            if let existing = node.children.first(where: { $0.name == name }) {
                // Update size for files (directories update via recursive bubble)
                if !existing.isDirectory {
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
                let child = scanSubtree(url: url, parent: node, showHiddenFiles: showHiddenFiles, excludedNames: excludedNames)
                node.children.append(child)
                changed = true
            } else {
                // New file
                let ext = url.pathExtension.lowercased()
                let child = FSNode(url: url, name: name, isDirectory: false, size: info.allocatedSize, fileExtension: ext, parent: node)
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
        excludedNames: Set<String>
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
                child = scanSubtree(url: childURL, parent: node, showHiddenFiles: showHiddenFiles, excludedNames: excludedNames)
            } else {
                let ext = childURL.pathExtension.lowercased()
                child = FSNode(url: childURL, name: childName, isDirectory: false, size: childInfo.allocatedSize, fileExtension: ext, parent: node)
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

    public func drillDown(into node: FSNode) {
        guard node.isDirectory else { return }
        drillStack.append(node)
        Task { await recomputeLayout() }
    }

    public func drillUp() {
        guard !drillStack.isEmpty else { return }
        drillStack.removeLast()
        Task { await recomputeLayout() }
    }

    public func select(_ node: FSNode?) {
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

    private nonisolated static func buildDuplicateGroups(root: FSNode) -> [[FSNode]] {
        var all: [FSNode] = []
        collectAll(node: root, into: &all)
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

    private nonisolated static func buildExtensionSummaries(root: FSNode, map: ExtensionColorMap) -> [ExtensionSummary] {
        var groups: [String: (count: Int, size: Int64)] = [:]
        collectExtensions(node: root, into: &groups)
        let total = Double(root.size)
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

    private nonisolated static func tagSafetyLevels(node: FSNode) {
        var stack: [FSNode] = [node]
        while !stack.isEmpty {
            let n = stack.removeLast()
            n.safetyLevel = SafetyAnalyzer.level(for: n)
            stack.append(contentsOf: n.children)
        }
    }

    private nonisolated static func sortAllChildren(node: FSNode) {
        var stack: [FSNode] = [node]
        while !stack.isEmpty {
            let n = stack.removeLast()
            guard !n.children.isEmpty else { continue }
            n.children.sort { $0.size > $1.size }
            stack.append(contentsOf: n.children)
        }
    }

    private nonisolated static func collectAll(node: FSNode, into list: inout [FSNode]) {
        var stack = [node]
        while !stack.isEmpty {
            let n = stack.removeLast()
            list.append(n)
            stack.append(contentsOf: n.children)
        }
    }

    private nonisolated static func collectExtensions(node: FSNode, into groups: inout [String: (count: Int, size: Int64)]) {
        var stack = [node]
        while !stack.isEmpty {
            let n = stack.removeLast()
            if !n.isDirectory {
                groups[n.fileExtension, default: (0, 0)].count += 1
                groups[n.fileExtension, default: (0, 0)].size  += n.size
            }
            stack.append(contentsOf: n.children)
        }
    }

    public func exportCSV() {
        guard let root else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(root.name)-disk-usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached(priority: .utility) { [root] in
            var lines = ["Path,Size (bytes),Human Size,Type,Duplicate Group"]
            Self.appendCSV(node: root, to: &lines)
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

    private nonisolated static func appendCSV(node: FSNode, to lines: inout [String]) {
        var stack: [FSNode] = [node]
        while let current = stack.popLast() {
            let type = current.isDirectory ? "directory" : current.fileExtension
            let group = current.duplicateGroupID?.uuidString ?? ""
            lines.append([
                csvEscape(current.url.path),
                "\(current.size)",
                csvEscape(ByteFormatter.string(from: current.size)),
                csvEscape(type),
                csvEscape(group)
            ].joined(separator: ","))
            stack.append(contentsOf: current.children)
        }
    }
}
