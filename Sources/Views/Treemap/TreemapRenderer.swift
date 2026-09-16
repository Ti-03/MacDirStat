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

        // Bounding boxes of labels drawn so far; a label that would overlap
        // one of them is skipped, so adjacent arcs never print on top of each
        // other ("PlugInsMediaProvMotionEffect.fxp").
        // The center disc is drawn above the canvas by TreemapView, so it is
        // reserved up front: inner-ring labels must not run underneath it.
        var placedLabels: [CGRect] = []

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
                drawLabel(context: &context, cell: cell, center: center, showFileCount: showFileCount, placedLabels: &placedLabels)
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

    private static func drawLabel(context: inout GraphicsContext, cell: TreemapCell, center: CGPoint, showFileCount: Bool, placedLabels: inout [CGRect]) {
        let arcLen = cell.arcLength
        let bandH  = cell.outerRadius - cell.innerRadius
        guard arcLen > 38, bandH > 12 else { return }

        let r  = cell.midRadius
        // `midAngle` is Double and the radii are CGFloat; mixing them inside one
        // expression is ambiguous to the compiler on SDKs where the two types
        // are distinct, so the trig is converted once, explicitly. (It is also
        // reused by the placement loop below instead of being recomputed.)
        let cosMid = CGFloat(cos(cell.midAngle))
        let sinMid = CGFloat(sin(cell.midAngle))
        let pt = CGPoint(x: center.x + r * cosMid, y: center.y + r * sinMid)
        let twoLine = arcLen > 72 && bandH > 26

        var ctx = context
        ctx.addFilter(.shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1))

        let sizeText = ctx.resolve(
            Text(ByteFormatter.string(from: cell.node.size))
                .font(.system(size: 8.5, weight: .regular))
                .foregroundColor(.white.opacity(0.75))
        )
        let showCount = twoLine && showFileCount && cell.node.isDirectory && !cell.node.children.isEmpty
        let countText: GraphicsContext.ResolvedText? = showCount ? ctx.resolve(
            Text(cell.node.itemCountLabel)
                .font(.system(size: 7.5, weight: .regular))
                .foregroundColor(.white.opacity(0.55))
        ) : nil
        let ss = twoLine ? sizeText.measure(in: unbounded) : .zero
        let cs = countText?.measure(in: unbounded) ?? .zero
        let gap: CGFloat = 2

        // Start at the widest label the arc allows and narrow it until the
        // block clears the center disc (inner ring labels are often wider than
        // the ring is deep). A block that collides with another label is
        // simply dropped: shrinking would not move it out of the way.
        var maxW = min(arcLen - 8, 120.0)
        while maxW >= 30 {
            guard let (nameText, ns) = fittedName(cell.node.name, size: twoLine ? 10.5 : 9.5, weight: twoLine ? .semibold : .medium, maxW: maxW, ctx: ctx) else { return }
            var blockH = ns.height
            if twoLine { blockH += gap + ss.height }
            if countText != nil { blockH += gap + cs.height }
            let blockW = max(ns.width, twoLine ? ss.width : 0, cs.width)

            // Slide outward along the radius (staying inside the arc's own
            // band) before giving up width: inner-ring labels are usually
            // wider than the band is deep, and a nudge of a few points is
            // enough to clear the disc.
            var pt = pt
            var rect = CGRect.zero
            var clears = false
            // The block may overhang its arc's outer edge by up to a quarter of
            // its height; the visible disc is a few points smaller than the
            // layout radius, so the disc test uses the unpadded block.
            let maxShift = max(0, cell.outerRadius - r - blockH / 4)
            for shift in stride(from: CGFloat(0), through: maxShift, by: 2) {
                pt = CGPoint(x: center.x + (r + shift) * cosMid, y: center.y + (r + shift) * sinMid)
                let block = CGRect(x: pt.x - blockW / 2, y: pt.y - blockH / 2, width: blockW, height: blockH)
                rect = block.insetBy(dx: -3, dy: -2)
                if clearsCenterDisc(block, center: center) { clears = true; break }
            }
            if !clears { maxW -= 12; continue }
            guard !placedLabels.contains(where: { $0.intersects(rect) }) else { return }
            placedLabels.append(rect)

            var y = pt.y - blockH / 2 + ns.height / 2
            ctx.draw(nameText, at: CGPoint(x: pt.x, y: y), anchor: .center)
            if twoLine {
                y += ns.height / 2 + gap + ss.height / 2
                ctx.draw(sizeText, at: CGPoint(x: pt.x, y: y), anchor: .center)
            }
            if let countText {
                y += (twoLine ? ss.height : ns.height) / 2 + gap + cs.height / 2
                ctx.draw(countText, at: CGPoint(x: pt.x, y: y), anchor: .center)
            }
            return
        }
    }

    private static let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    // The center disc is drawn above the canvas by TreemapView, so a label
    // must not run underneath it: true when the disc stays out of `rect`.
    private static func clearsCenterDisc(_ rect: CGRect, center: CGPoint) -> Bool {
        let nearest = CGPoint(x: min(max(center.x, rect.minX), rect.maxX),
                              y: min(max(center.y, rect.minY), rect.maxY))
        return hypot(nearest.x - center.x, nearest.y - center.y) >= TreemapLayout.centerRadius
    }

    // Resolves `name` so that it fits in `maxW`, middle-truncating with an
    // ellipsis when it doesn't. Measuring inside a bounded width used to
    // report a size that fit while `draw` then painted the full natural width,
    // so long names spilled over neighbouring arcs. A label that would keep
    // fewer than 7 characters, or under 30% of the name, says nothing useful
    // ("Fr…ks"), so nil is returned and no label is drawn; the hover tooltip
    // still shows the full name.
    private static func fittedName(_ name: String, size: CGFloat, weight: Font.Weight, maxW: CGFloat, ctx: GraphicsContext) -> (GraphicsContext.ResolvedText, CGSize)? {
        func resolve(_ s: String) -> (GraphicsContext.ResolvedText, CGSize) {
            let t = ctx.resolve(Text(s).font(.system(size: size, weight: weight)).foregroundColor(.white))
            return (t, t.measure(in: unbounded))
        }
        var (text, measured) = resolve(name)
        if measured.width <= maxW { return (text, measured) }
        let chars = Array(name)
        let minKeep = max(7, Int(Double(chars.count) * 0.3))
        // Proportional first guess, then shrink until it fits.
        var keep = max(2, Int(Double(chars.count) * Double(maxW / measured.width)) - 1)
        while keep >= minKeep {
            let candidate = String(chars.prefix((keep + 1) / 2)) + "…" + String(chars.suffix(keep / 2))
            (text, measured) = resolve(candidate)
            if measured.width <= maxW { return (text, measured) }
            keep -= 2
        }
        return nil
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
