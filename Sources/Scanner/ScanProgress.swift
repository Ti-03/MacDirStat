import Foundation

public enum ScanProgress: Sendable {
    case update(itemsScanned: Int, bytesFound: Int64)
    case completed(root: FSNode, deniedCount: Int)
    case failed(String)
}
