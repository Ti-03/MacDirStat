# MacDirStat

MacDirStat is a native macOS app that scans a folder and shows what's taking up
disk space, as an interactive radial treemap.

This guide is for **macOS users who have MacDirStat installed** (or built it
from source) and want to scan a folder, read the resulting chart, or look up
what a specific API does. You don't need any Swift experience to follow the
tutorial or how-to guide; the reference section assumes you are reading the
Swift source.

- New to MacDirStat? Start with the [tutorial](tutorial/first-scan.md).
- Trying to make sense of the colors in the chart? Read
  [How to read the treemap](how-to/read-the-treemap.md).
- Working on the codebase? See the [reference](reference/byte-formatter.md)
  section for the exact behavior of `ByteFormatter` and `TreemapLayout`.
