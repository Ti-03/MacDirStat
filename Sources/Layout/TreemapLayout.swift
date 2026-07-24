import SwiftUI
import AppKit

private extension Color {
    func darkened(by fraction: Double) -> Color {
        guard fraction > 0 else { return self }
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s),
                     brightness: max(0, Double(b) - fraction), opacity: Double(a))
    }
}

public struct TreemapLayout {

    static let centerRadius: CGFloat = 76
    private static let maxDepth = 5
    private static let minArcAngle: Double = 0.018

    // Gentle per-depth darkening so deep files stay recognisable
    private static let depthDarken: [Double] = [0.0, 0.10, 0.18, 0.26, 0.32, 0.38]

    public static func compute(root: FSNode, in rect: CGRect, colorMap: ExtensionColorMap) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        guard rect.width > 1, rect.height > 1, root.size > 0 else { return cells }

        let children = root.children.filter { $0.size > 0 }
        guard !children.isEmpty else { return cells }

        let maxR = min(rect.width, rect.height) / 2 - 10
        guard maxR > centerRadius + 20 else { return cells }
        let bandW = (maxR - centerRadius) / CGFloat(maxDepth)

        layout(children,
               parentStart: -.pi / 2, parentEnd: 1.5 * .pi,
               depth: 0, colorMap: colorMap,
               centerR: centerRadius, bandW: bandW,
               cells: &cells)
        return cells
    }

    private static func layout(
        _ children: [FSNode],
        parentStart: Double,
        parentEnd: Double,
        depth: Int,
        colorMap: ExtensionColorMap,
        centerR: CGFloat,
        bandW: CGFloat,
        cells: inout [TreemapCell]
    ) {
        guard depth < maxDepth else { return }

        let totalSize = children.reduce(Int64(0)) { $0 + $1.size }
        guard totalSize > 0 else { return }

        let totalAngle = parentEnd - parentStart
        let innerR = centerR + CGFloat(depth) * bandW
        let outerR = innerR + bandW - 3   // 3 pt radial gap between bands

        var angle = parentStart

        for child in children {
            let fraction = Double(child.size) / Double(totalSize)
            let arcAngle = fraction * totalAngle
            let arcEnd   = angle + arcAngle

            guard arcAngle >= minArcAngle else { angle = arcEnd; continue }

            let cellColor = color(for: child, depth: depth, colorMap: colorMap)

            cells.append(TreemapCell(
                node: child,
                startAngle: angle,
                endAngle: arcEnd,
                innerRadius: innerR,
                outerRadius: outerR,
                color: cellColor,
                depth: depth
            ))

            if child.isDirectory, !child.children.isEmpty {
                let sorted = child.children.filter { $0.size > 0 }
                layout(sorted,
                       parentStart: angle, parentEnd: arcEnd,
                       depth: depth + 1, colorMap: colorMap,
                       centerR: centerR, bandW: bandW,
                       cells: &cells)
            }

            angle = arcEnd
        }
    }

    // ── Color assignment ─────────────────────────────────────────────────────

    static func directoryHue(for name: String) -> Double {
        let hash = name.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
        return Double(hash % 360) / 360.0
    }

    private static func color(for node: FSNode, depth: Int, colorMap: ExtensionColorMap) -> Color {
        if node.isSynthetic {
            // Distinct muted gray so the hidden-space reconciliation node reads as
            // "not a real file" at a glance, rather than blending into the chart.
            return Color(hue: 0, saturation: 0, brightness: 0.35)
        }
        if node.isDirectory {
            // Directories: muted tinted containers — hue from name hash, low saturation
            let hue  = directoryHue(for: node.name)
            let fade = Double(depth) * 0.05
            return Color(hue: hue,
                         saturation: max(0.12, 0.28 - fade),
                         brightness: max(0.30, 0.55 - fade))
        } else {
            let base   = colorMap.color(for: node.fileExtension)
            let darken = depth < depthDarken.count ? depthDarken[depth] : 0.38
            return darken > 0 ? base.darkened(by: darken) : base
        }
    }
}
