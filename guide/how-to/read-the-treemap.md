# How to read the treemap

This guide is for MacDirStat users who have already run a scan and want to
understand what the chart is showing them.

## Understand what an arc represents

Each arc in the ring is one file or folder. Two things about an arc carry
information:

- **Angle.** A wider arc holds more disk space. Angle is proportional to
  size within its parent, not to the whole disk.
- **Radius (distance from center).** Deeper arcs sit farther from the
  center. A file three folders deep sits in the third ring band out.

## Understand the default colors ("By Type")

By default, MacDirStat colors files by category, not by individual
extension:

| Color   | Category            | Example extensions        |
| ------- | -------------------- | -------------------------- |
| Orange  | Video                | `mp4`, `mov`, `mkv`         |
| Emerald | Images               | `jpg`, `png`, `heic`        |
| Cyan    | Audio                | `mp3`, `wav`, `flac`        |
| Blue    | Code                 | `swift`, `py`, `js`         |
| Violet  | Documents            | `pdf`, `docx`, `md`         |
| Red     | Archives             | `zip`, `dmg`, `pkg`         |
| Yellow  | Data / config        | `json`, `yaml`, `sqlite`    |
| Teal    | Web                  | `html`, `css`               |
| Pink    | Fonts                | `ttf`, `otf`, `woff`        |
| Lime    | 3D / models          | `obj`, `fbx`, `gltf`        |

An extension MacDirStat doesn't recognize gets a stable color derived from
its name, so the same unknown extension is always the same color across a
scan. Folders and files use different color schemes: each folder gets a muted,
low-saturation tint based on its name, so folders never compete visually
with the files inside them. Files also darken slightly with depth, so you
can tell a top-level file from one buried five folders down at a glance.

## Change the color scheme or size units

1. Click the gear icon (**Settings & About**) in the dashboard.
2. Under **Appearance**:
   - **Color scheme**: choose **By Type** (default), **Rainbow** (one hue
     per extension, no category grouping), or **Mono** (grayscale, useful
     for spotting size outliers without color as a distraction).
   - **File size units**: choose **Decimal** (KB/MB/GB, 1000-based) or
     **Binary** (KiB/MiB/GiB, 1024-based).

## Zoom in and out

- Click an arc that represents a folder to make it the new center ring.
- Click the center circle to zoom back out one level.

## See also

- [Scan your first folder](../tutorial/first-scan.md) if you haven't run a
  scan yet.
- [TreemapLayout reference](../reference/treemap-layout.md) for exactly how
  angles and colors are computed.
