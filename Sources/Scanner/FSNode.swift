import Foundation

// Identity of a hardlinked inode: lets the refresh path recognize that two
// directory entries are the same underlying file, the way the scanner's
// scan-time VisitedSet does.
public struct HardLinkRef: Hashable, Sendable {
    public let dev: UInt64
    public let ino: UInt64
    public init(dev: UInt64, ino: UInt64) {
        self.dev = dev
        self.ino = ino
    }
}

public final class FSNode: Identifiable, @unchecked Sendable {
    public let id: UUID = UUID()
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public var size: Int64
    public var children: [FSNode]
    public weak var parent: FSNode?
    public let fileExtension: String
    public var duplicateGroupID: UUID?
    public var safetyLevel: SafetyLevel = .caution
    public var isAccessDenied: Bool = false
    public var isSynthetic: Bool = false
    // Set only for files with st_nlink > 1 (both the size-carrying node and its 0-size siblings).
    public var hardLinkRef: HardLinkRef?
    // True when the traversal collapsed this directory's entire subtree into
    // this single node instead of materializing its descendants (see
    // AtomicDirectorySummary.swift). `children` is always empty in that case.
    public var isAutoSummarized: Bool = false
    // Total number of files collapsed under this node by auto-summarization.
    // 0 for normal (non-summarized) nodes.
    public var descendantFileCount: Int = 0

    public init(url: URL, name: String, isDirectory: Bool, size: Int64, fileExtension: String, parent: FSNode? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.fileExtension = fileExtension
        self.children = []
        self.parent = parent
    }
}

public extension FSNode {
    var optionalChildren: [FSNode]? {
        guard isDirectory && !children.isEmpty else { return nil }
        return children
    }
}
