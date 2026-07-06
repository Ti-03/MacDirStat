import Foundation

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
