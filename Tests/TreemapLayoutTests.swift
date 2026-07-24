import XCTest
import SwiftUI
@testable import MacDirStat

final class TreemapLayoutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // ByteFormatter reads "useBinarySize" from UserDefaults. Pin it to the
        // default (decimal / SI) so the formatter tests are deterministic
        // regardless of any value the app left on this machine.
        UserDefaults.standard.set(false, forKey: "useBinarySize")
    }

    func test_extension_color_map_returns_consistent_color() {
        let root = makeTree([("a.pdf", 100), ("b.pdf", 200), ("c.mp4", 300)])
        let map = ExtensionColorMap(root: root)
        let c1 = map.color(for: "pdf")
        let c2 = map.color(for: "pdf")
        XCTAssertEqual(c1, c2, "same extension must return same color")
    }

    func test_extension_color_map_different_extensions_get_different_colors() {
        let root = makeTree([("a.pdf", 100), ("b.mp4", 200)])
        let map = ExtensionColorMap(root: root)
        XCTAssertNotEqual(map.color(for: "pdf"), map.color(for: "mp4"))
    }

    func test_directory_hue_is_deterministic_and_bounded() {
        let name = "Documents"
        let expected = name.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
        let hue = TreemapLayout.directoryHue(for: name)
        XCTAssertEqual(hue, Double(expected % 360) / 360.0)
        XCTAssertGreaterThanOrEqual(hue, 0)
        XCTAssertLessThan(hue, 1)
        XCTAssertNotEqual(TreemapLayout.directoryHue(for: "aaa"), TreemapLayout.directoryHue(for: "zzz"))
    }

    func test_byte_formatter_kb() {
        XCTAssertEqual(ByteFormatter.string(from: 1_000), "1.0 KB")
    }

    func test_byte_formatter_mb() {
        XCTAssertEqual(ByteFormatter.string(from: 1_000_000), "1.0 MB")
    }

    func test_byte_formatter_gb() {
        XCTAssertEqual(ByteFormatter.string(from: 1_000_000_000), "1.0 GB")
    }

    func test_byte_formatter_bytes() {
        XCTAssertEqual(ByteFormatter.string(from: 500), "500 B")
    }

    // MARK: - Helpers

    // Builds an FSNode fixture (as before) and converts it to a FileTree,
    // returning a FileNode handle onto its root — TreemapLayout/ExtensionColorMap
    // are now FileNode-based, but the fixture construction itself is unchanged.
    func makeTree(_ files: [(String, Int64)]) -> FileNode {
        let root = FSNode(url: URL(fileURLWithPath: "/"), name: "/", isDirectory: true, size: 0, fileExtension: "", parent: nil)
        for (name, size) in files {
            let ext = (name as NSString).pathExtension.lowercased()
            let child = FSNode(url: URL(fileURLWithPath: "/\(name)"), name: name, isDirectory: false, size: size, fileExtension: ext, parent: root)
            root.children.append(child)
            root.size += size
        }
        let tree = FileTreeBuilder.build(from: root, rootPath: "/")
        return FileNode(tree: tree, index: tree.rootIndex)
    }

    // The layout is a radial sunburst: a node's children fill the angular range
    // [-pi/2, 1.5*pi] (a full 2*pi circle), each child's arc proportional to its
    // size. Cells sit in radial bands. These tests assert on angles/radii.
    // Note: compute() needs min(width, height) > ~212 to produce any cells.

    func test_layout_single_item_spans_full_circle() {
        let root = makeTree([("a.pdf", 1000)])
        let map = ExtensionColorMap(root: root)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let cells = TreemapLayout.compute(root: root, in: rect, colorMap: map)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].endAngle - cells[0].startAngle, 2 * .pi, accuracy: 0.001)
    }

    func test_layout_two_equal_items_split_circle_evenly() {
        let root = makeTree([("a.pdf", 500), ("b.mp4", 500)])
        let map = ExtensionColorMap(root: root)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let cells = TreemapLayout.compute(root: root, in: rect, colorMap: map)
        XCTAssertEqual(cells.count, 2)
        for cell in cells {
            XCTAssertEqual(cell.endAngle - cell.startAngle, .pi, accuracy: 0.001)
        }
        let totalArc = cells.reduce(0.0) { $0 + ($1.endAngle - $1.startAngle) }
        XCTAssertEqual(totalArc, 2 * .pi, accuracy: 0.001)
    }

    func test_layout_sibling_arcs_dont_overlap() {
        let root = makeTree([("a.pdf", 300), ("b.mp4", 200), ("c.zip", 100), ("d.txt", 400)])
        let map = ExtensionColorMap(root: root)
        let rect = CGRect(x: 0, y: 0, width: 500, height: 500)
        let cells = TreemapLayout.compute(root: root, in: rect, colorMap: map)
            .sorted { $0.startAngle < $1.startAngle }
        for i in 1..<cells.count {
            XCTAssertGreaterThanOrEqual(cells[i].startAngle, cells[i - 1].endAngle - 0.001,
                                        "arc \(i) overlaps the previous sibling arc")
        }
    }

    func test_layout_cells_within_radial_bounds() {
        let root = makeTree([("a.pdf", 100), ("b.mp4", 200), ("c.zip", 300)])
        let map = ExtensionColorMap(root: root)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let maxR = min(rect.width, rect.height) / 2 - 10
        let cells = TreemapLayout.compute(root: root, in: rect, colorMap: map)
        XCTAssertFalse(cells.isEmpty)
        for cell in cells {
            XCTAssertGreaterThanOrEqual(cell.innerRadius, TreemapLayout.centerRadius)
            XCTAssertLessThanOrEqual(cell.outerRadius, maxR + 0.001)
            XCTAssertGreaterThanOrEqual(cell.startAngle, -.pi / 2 - 0.001)
            XCTAssertLessThanOrEqual(cell.endAngle, 1.5 * .pi + 0.001)
        }
    }

    func test_layout_empty_children_returns_no_cells() {
        let root = makeTree([])
        let map = ExtensionColorMap(root: root)
        let cells = TreemapLayout.compute(root: root, in: CGRect(x: 0, y: 0, width: 400, height: 400), colorMap: map)
        XCTAssertTrue(cells.isEmpty)
    }

    func test_layout_larger_items_get_larger_arcs() {
        let root = makeTree([("small.txt", 100), ("large.pdf", 900)])
        let map = ExtensionColorMap(root: root)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let cells = TreemapLayout.compute(root: root, in: rect, colorMap: map)
        XCTAssertEqual(cells.count, 2)
        let largeCell = cells.first { $0.node.name == "large.pdf" }!
        let smallCell = cells.first { $0.node.name == "small.txt" }!
        XCTAssertGreaterThan(largeCell.endAngle - largeCell.startAngle,
                             smallCell.endAngle - smallCell.startAngle)
    }
}
