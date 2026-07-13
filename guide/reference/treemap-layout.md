# TreemapLayout

`TreemapLayout` is a stateless struct in
[`Sources/Layout/TreemapLayout.swift`](https://github.com/Ti-03/MacDirStat/blob/main/Sources/Layout/TreemapLayout.swift)
that turns a file-system tree into the arcs drawn on screen. It has one
public entry point.

## `TreemapLayout.compute(root:in:colorMap:)`

```swift
public static func compute(
    root: FSNode,
    in rect: CGRect,
    colorMap: ExtensionColorMap
) -> [TreemapCell]
```

Computes one [`TreemapCell`](#treemapcell) per visible file or folder under
`root`, laid out to fit inside `rect`.

- `root`: the folder currently zoomed into. Only its direct and nested
  children are laid out, up to a fixed maximum depth of 5.
- `rect`: the drawing area. The available radius is derived from
  `min(rect.width, rect.height)`.
- `colorMap`: the active [`ExtensionColorMap`](#color-assignment), which
  encodes the user's chosen color scheme (By Type, Rainbow, or Mono).

Returns an empty array if `rect` is too small to fit a ring, or if `root`
has no children with `size > 0`.

### Layout rule

Each child's arc angle is proportional to its share of its parent's total
size:

```swift
let fraction = Double(child.size) / Double(totalSize)
let arcAngle = fraction * totalAngle
```

An arc smaller than `minArcAngle` (about 1 degree) is skipped entirely
rather than drawn as an unreadable sliver. Folders recurse into their own
children at the next radius band; files don't.

## `TreemapCell`

```swift
public struct TreemapCell: Identifiable {
    public let node: FSNode
    public let startAngle: Double   // radians; 0 = right, clockwise
    public let endAngle: Double
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    public let color: Color
    public let depth: Int
}
```

One cell per arc. `startAngle`/`endAngle` are in radians; `innerRadius`/
`outerRadius` define the ring band for the cell's depth.

## Color assignment

Colors aren't assigned by `TreemapLayout` directly; it delegates to
`ExtensionColorMap.color(for:)` for files and computes a muted per-folder
tint by hashing the folder's name for directories. Files also darken by a
fixed amount per depth (from 0% at depth 0 up to 38% at depth 5+), so a
`.mp4` five folders deep is visibly darker than one at the top level, even
though both are "orange."
