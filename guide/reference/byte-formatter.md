# ByteFormatter

`ByteFormatter` is a stateless enum in
[`Sources/Views/Shared/ByteFormatter.swift`](https://github.com/Ti-03/MacDirStat/blob/main/Sources/Views/Shared/ByteFormatter.swift)
that turns a raw byte count into a human-readable string.

## `ByteFormatter.string(from:)`

```swift
public static func string(from bytes: Int64) -> String
```

Formats `bytes` using the unit style the user chose in **Settings →
Appearance → File size units**, read from
`UserDefaults.standard.bool(forKey: "useBinarySize")`.

| Setting  | Base | Units                          |
| -------- | ---- | ------------------------------- |
| Decimal (default) | 1000 | B, KB, MB, GB, TB   |
| Binary   | 1024 | B, KiB, MiB, GiB, TiB           |

Returns a string with one decimal place for any unit above bytes, for
example `"4.2 GB"` or `"512 B"`.

### Examples

```swift
ByteFormatter.string(from: 512)          // "512 B"
ByteFormatter.string(from: 1_500_000)    // "1.5 MB"   (decimal)
ByteFormatter.string(from: 1_572_864)    // "1.5 MiB"  (binary)
```

## Notes for contributors

`ByteFormatter` reads `UserDefaults` directly rather than taking a
parameter, so it always reflects the user's current setting without
threading it through every call site. If you add a call to
`ByteFormatter.string(from:)` in a `View`, no extra wiring is needed; it
already reacts to the setting the same way the rest of the app does.
