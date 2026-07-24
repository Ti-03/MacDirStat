import Foundation

// Per-node payload stored contiguously in `FileTree.records`. This is the
// flat, struct-of-arrays replacement for `FSNode`'s per-node instance fields:
// no URL and no UUID are stored per record (that was FSNode's memory cost on
// huge scans) — the absolute path is reconstructed on demand from names +
// parentIndex (see `FileTree.path(of:)` / `FileNode.url`), and node identity
// for SwiftUI purposes is the (tree, index) pair (see `FileNode.id`).
public struct FileNodeRecord: Sendable {
    public let name: String
    public let isDirectory: Bool
    public var size: Int64
    public let fileExtension: String
    public var isAccessDenied: Bool
    public var isSynthetic: Bool
    public var isAutoSummarized: Bool
    public var descendantFileCount: Int
    public var hardLinkRef: HardLinkRef?
    public var duplicateGroupID: UUID?
    public var safetyLevel: SafetyLevel

    public init(
        name: String,
        isDirectory: Bool,
        size: Int64,
        fileExtension: String,
        isAccessDenied: Bool = false,
        isSynthetic: Bool = false,
        isAutoSummarized: Bool = false,
        descendantFileCount: Int = 0,
        hardLinkRef: HardLinkRef? = nil,
        duplicateGroupID: UUID? = nil,
        safetyLevel: SafetyLevel = .caution
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.fileExtension = fileExtension
        self.isAccessDenied = isAccessDenied
        self.isSynthetic = isSynthetic
        self.isAutoSummarized = isAutoSummarized
        self.descendantFileCount = descendantFileCount
        self.hardLinkRef = hardLinkRef
        self.duplicateGroupID = duplicateGroupID
        self.safetyLevel = safetyLevel
    }
}
