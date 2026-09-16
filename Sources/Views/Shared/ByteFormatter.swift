import Foundation

public enum ByteFormatter {
    private static let decimalUnits = ["B", "KB", "MB", "GB", "TB", "PB"]
    private static let binaryUnits = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

    /// Formats bytes using the user's chosen unit style (decimal SI or binary IEC).
    public static func string(from bytes: Int64) -> String {
        string(from: bytes, binary: UserDefaults.standard.bool(forKey: "useBinarySize"))
    }

    public static func string(from bytes: Int64, binary: Bool) -> String {
        let base: Double = binary ? 1_024 : 1_000
        let units = binary ? binaryUnits : decimalUnits
        var value = Double(bytes)
        var unit = 0
        // Step up while the value would still print as "1000.0" or more, so a
        // hair under a unit boundary reads "1.0 MB" instead of "1000.0 KB".
        while unit < units.count - 1, value >= base - 0.05 {
            value /= base
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}
