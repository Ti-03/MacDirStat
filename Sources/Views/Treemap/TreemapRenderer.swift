import SwiftUI

struct TreemapRenderer {

    private static let padAngle: Double = 0.005

    static func draw(
        cells: [TreemapCell],
        hoveredNode: FileNode?,
        selectedNode: FileNode?,
        highlightedExtension: String?,
        duplicatesReady: Bool,
        pulsePhase: Double,
        showFileCount: Bool,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let isSpotlighting = hoveredNode != nil
        let isFiltering    = highlightedExtension != nil

        // ── Pass 1 — glow layers (drawn under everything) ───────────────────
        // Selected arc: pulsing halo
        if let sel = selectedNode {
            for cell in cells where cell.node.id == sel.id {
                let path = makePath(cell: cell, center: center)
                let pulse = 0.5 + 0.5 * sin(pulsePhase * .pi * 2)   // 0…1
                let radius  = 7.0 + pulse * 9.0
                let opacity = 0.45 + pulse * 0.40
                var glowCtx = context
                glowCtx.addFilter(.shadow(color: cell.color.opacity(opacity),
                                          radius: radius, x: 0, y: 0))
                glowCtx.stroke(path, with: .color(cell.color.opacity(0.9)), lineWidth: 2.5)
                break
            }
        }

        // Hovered arc: coloured outer glow
        if let hov = hoveredNode {
            for cell in cells where cell.node.id == hov.id {
                let path = makePath(cell: cell, center: center)
                var glowCtx = context
                glowCtx.addFilter(.shadow(color: cell.color.opacity(0.80), radius: 22, x: 0, y: 0))
                glowCtx.fill(path, with: .color(cell.color.opacity(0.35)))
                break
            }
        }

        // ── Pass 2 — main fills ──────────────────────────────────────────────
        for cell in cells {
            let arcSpan = cell.endAngle - cell.startAngle
            guard arcSpan > padAngle * 2 else { continue }

            let isHovered   = cell.node.id == hoveredNode?.id
            let isSelected  = cell.node.id == selectedNode?.id
            let isFiltered  = isFiltering && cell.node.fileExtension != highlightedExtension
            let isSpotlit   = isSpotlighting && !isHovered && !isSelected

            let path = makePath(cell: cell, center: center)

            // Opacity
            let opacity: Double
            if isFiltered        { opacity = 0.07 }
            else if isSpotlit    { opacity = 0.09 }
            else if isHovered    { opacity = cell.node.isDirectory ? 1.00 : 0.98 }
            else                 { opacity = cell.node.isDirectory ? 0.82 : 0.90 }

            context.fill(path, with: .color(cell.color.opacity(opacity)))

            // Hover brightness lift
            if isHovered, !isFiltered {
                context.fill(path, with: .color(.white.opacity(0.14)))
            }

            // Subtle separator stroke (only for visible cells)
            if !isFiltered, !isSpotlit {
                context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 0.5)
            }

            // Duplicate dot
            if duplicatesReady, cell.node.duplicateGroupID != nil, !isFiltered, !isSpotlit {
                let r  = cell.midRadius
                let cx = center.x + r * cos(cell.midAngle)
                let cy = center.y + r * sin(cell.midAngle)
                let dot = Path(ellipseIn: CGRect(x: cx - 2.5, y: cy - 2.5, width: 5, height: 5))
                context.fill(dot, with: .color(.white.opacity(0.8)))
            }

            // Selection ring
            if isSelected {
                context.stroke(path, with: .color(.white.opacity(0.90)), lineWidth: 1.8)
            }

            // Label
            if !isFiltered, !isSpotlit {
                drawLabel(context: &context, cell: cell, center: center, showFileCount: showFileCount)
            }
        }
    }

    // MARK: - Path

    static func makePath(cell: TreemapCell, center: CGPoint) -> Path {
        let pad = min(padAngle, (cell.endAngle - cell.startAngle) * 0.08)
        let s = cell.startAngle + pad
        let e = cell.endAngle   - pad
        guard e > s else { return Path() }

        var path = Path()
        path.addArc(center: center, radius: cell.outerRadius,
                    startAngle: .radians(s), endAngle: .radians(e), clockwise: false)
        path.addArc(center: center, radius: cell.innerRadius,
                    startAngle: .radians(e), endAngle: .radians(s), clockwise: true)
        path.closeSubpath()
        return path
    }

    // MARK: - Labels

    private static func drawLabel(context: inout GraphicsContext, cell: TreemapCell, center: CGPoint, showFileCount: Bool) {
        let arcLen = cell.arcLength
        let bandH  = cell.outerRadius - cell.innerRadius
        guard arcLen > 38, bandH > 12 else { return }

        let r  = cell.midRadius
        let cx = center.x + r * cos(cell.midAngle)
        let cy = center.y + r * sin(cell.midAngle)
        let pt = CGPoint(x: cx, y: cy)
        let maxW = min(arcLen - 8, 120.0)

        var ctx = context
        ctx.addFilter(.shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1))

        if arcLen > 72, bandH > 26 {
            let nameText = ctx.resolve(
                Text(cell.node.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
            )
            let sizeText = ctx.resolve(
                Text(ByteFormatter.string(from: cell.node.size))
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.75))
            )

            let showCount = showFileCount && cell.node.isDirectory && !cell.node.children.isEmpty
            let countText: GraphicsContext.ResolvedText? = showCount ? ctx.resolve(
                Text("\(cell.node.children.count) items")
                    .font(.system(size: 7.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))
            ) : nil

            let ns = nameText.measure(in: CGSize(width: maxW, height: 20))
            guard ns.width <= maxW else { return }
            let ss = sizeText.measure(in: CGSize(width: maxW, height: 16))
            let cs = countText?.measure(in: CGSize(width: maxW, height: 14)) ?? .zero
            let gap: CGFloat = 2
            var blockH = ns.height + gap + ss.height
            if countText != nil { blockH += gap + cs.height }

            var y = pt.y - blockH / 2 + ns.height / 2
            ctx.draw(nameText, at: CGPoint(x: pt.x, y: y), anchor: .center)
            y += ns.height / 2 + gap + ss.height / 2
            if ss.width <= maxW {
                ctx.draw(sizeText, at: CGPoint(x: pt.x, y: y), anchor: .center)
            }
            if let countText, cs.width <= maxW {
                y += ss.height / 2 + gap + cs.height / 2
                ctx.draw(countText, at: CGPoint(x: pt.x, y: y), anchor: .center)
            }
        } else {
            let nameText = ctx.resolve(
                Text(cell.node.name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.white)
            )
            let ns = nameText.measure(in: CGSize(width: maxW, height: 20))
            guard ns.width <= maxW else { return }
            ctx.draw(nameText, at: pt, anchor: .center)
        }
    }

    // MARK: - Hit testing

    static func cell(at point: CGPoint, center: CGPoint, in cells: [TreemapCell]) -> TreemapCell? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r  = sqrt(dx * dx + dy * dy)
        var angle = atan2(dy, dx)
        if angle < -.pi / 2 { angle += 2 * .pi }

        return cells.last {
            r >= $0.innerRadius && r < $0.outerRadius &&
            angle >= $0.startAngle && angle < $0.endAngle
        }
    }

    static func isInCenter(point: CGPoint, center: CGPoint) -> Bool {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return sqrt(dx * dx + dy * dy) < TreemapLayout.centerRadius
    }
}
