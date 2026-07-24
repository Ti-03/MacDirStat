import SwiftUI

/// Arc-based cell for the sunburst visualization.
public struct TreemapCell: Identifiable {
    public let id: UUID = UUID()
    public let node: FileNode
    public let startAngle: Double    // radians; 0 = right, increases clockwise on screen
    public let endAngle: Double
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    public let color: Color
    public let depth: Int

    var midAngle: Double { (startAngle + endAngle) / 2 }
    var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
    /// Arc length at mid-radius — used to decide whether to draw a label
    var arcLength: CGFloat { midRadius * CGFloat(endAngle - startAngle) }
}
