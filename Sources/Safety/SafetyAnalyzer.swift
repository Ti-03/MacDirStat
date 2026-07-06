import Foundation

public enum SafetyLevel: Equatable {
    case safe     // Regeneratable artifact — confident it's okay to delete
    case caution  // Unknown or user data — review before deleting
    case danger   // System or critical app data — do not delete
}

/// Classifies an FSNode as safe / caution / danger based on its path.
/// Rules are evaluated top-down with danger taking priority over safe.
/// All string work is done once during post-scan tagging — nothing in the render path.
public struct SafetyAnalyzer {

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: - Bulk tagging (no string allocations — just enum assignment)

    public static func level(for node: FSNode) -> SafetyLevel {
        // Synthetic nodes (e.g. the hidden-space reconciliation entry) don't point
        // at a real, deletable file — always treat them as the most protective
        // level so nothing ever attempts to trash/move them.
        if node.isSynthetic { return .danger }
        let path = node.url.path
        let name = node.name
        if isDanger(path: path, name: name) { return .danger }
        if isSafe(path: path, name: name)   { return .safe   }
        return .caution
    }

    // MARK: - On-demand reason (called only when UI needs to display it)

    public static func reason(for node: FSNode) -> String? {
        if node.isSynthetic {
            return "Represents space macOS reports as used but the scanner can't read or enumerate (snapshots, purgeable space, protected folders)"
        }
        let path = node.url.path
        let name = node.name
        return dangerReason(path: path, name: name)
            ?? safeReason(path: path, name: name)
    }

    // MARK: - Danger

    private static func isDanger(path: String, name: String) -> Bool {
        dangerReason(path: path, name: name) != nil
    }

    private static func dangerReason(path: String, name: String) -> String? {
        // ── Core macOS system directories ───────────────────────────────────
        for (prefix, reason) in systemDangerPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return reason }
        }

        // ── Root-level /Library (distinct from ~/Library) ───────────────────
        if path == "/Library" || path.hasPrefix("/Library/") {
            return "Shared system and application data"
        }

        // ── Inside an .app bundle ───────────────────────────────────────────
        if path.contains(".app/Contents") {
            return "Inside an application bundle — do not delete"
        }

        // ── Critical user ~/Library subdirectories ──────────────────────────
        let h = home
        for (suffix, reason) in criticalUserLibrarySuffixes {
            let full = "\(h)/Library/\(suffix)"
            if path == full || path.hasPrefix(full + "/") { return reason }
        }

        // ── Git history ─────────────────────────────────────────────────────
        // .git holds ALL commits. Deleting it is irreversible.
        if name == ".git" {
            return "Git repository — contains your entire version history"
        }

        // ── Applications folders ─────────────────────────────────────────────
        if path == "/Applications" || path == "\(h)/Applications" {
            return "Installed applications"
        }

        return nil
    }

    // Static data — allocated once, not per-call
    private static let systemDangerPrefixes: [(String, String)] = [
        ("/System",      "Core macOS system files — required for the OS"),
        ("/usr",         "Unix system utilities and libraries"),
        ("/bin",         "Essential system binaries"),
        ("/sbin",        "System administration binaries"),
        ("/private/etc", "System configuration files"),
    ]

    private static let criticalUserLibrarySuffixes: [(String, String)] = [
        ("Application Support", "App data — deleting may permanently break applications"),
        ("Preferences",         "Application preferences and settings"),
        ("Keychains",           "Passwords and security certificates"),
        ("Mail",                "Your email messages and accounts"),
        ("Messages",            "iMessage and SMS history"),
        ("Safari",              "Safari browsing data"),
        ("Cookies",             "Browser and app session cookies"),
        ("HomeKit",             "Smart home configuration"),
        ("Health",              "Health and fitness data"),
        ("Photos",              "Photos library metadata"),
    ]

    // MARK: - Safe

    private static func isSafe(path: String, name: String) -> Bool {
        safeReason(path: path, name: name) != nil
    }

    private static func safeReason(path: String, name: String) -> String? {
        let h = home

        // ── macOS-managed caches (the OS clears these itself under memory pressure) ──
        if path == "\(h)/Library/Caches" || path.hasPrefix("\(h)/Library/Caches/") {
            return "macOS app cache — the system manages this automatically"
        }
        if path == "/Library/Caches" || path.hasPrefix("/Library/Caches/") {
            return "System-wide app cache"
        }

        // ── Log files ───────────────────────────────────────────────────────
        if path == "\(h)/Library/Logs" || path.hasPrefix("\(h)/Library/Logs/") {
            return "Application log files"
        }
        if path == "/Library/Logs" || path.hasPrefix("/Library/Logs/") {
            return "System log files"
        }

        // ── macOS temp directories ──────────────────────────────────────────
        if path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp") {
            return "Temporary files — cleared on restart"
        }
        if path.hasPrefix("/private/var/folders/") {
            return "Per-user temp files (TMPDIR) — cleared by macOS"
        }

        // ── Xcode ───────────────────────────────────────────────────────────
        if path.hasPrefix("\(h)/Library/Developer/Xcode/DerivedData") {
            return "Xcode build cache — regenerated automatically on next build"
        }
        if path.hasPrefix("\(h)/Library/Developer/CoreSimulator/Caches") {
            return "iOS/macOS Simulator caches"
        }
        if path.hasPrefix("\(h)/Library/Developer/CoreSimulator/Devices") {
            return "Simulator device images — re-created when needed"
        }

        // ── npm / yarn / pnpm ───────────────────────────────────────────────
        // node_modules is the single most common large junk directory on developer Macs
        if name == "node_modules" {
            return "npm/yarn/pnpm packages — restore with `npm install`"
        }

        // ── Swift Package Manager ───────────────────────────────────────────
        // Only flag .build when it's clearly inside a user project, not a system path
        if name == ".build" && path.hasPrefix(h) {
            return "Swift Package Manager build artifacts"
        }

        // ── Python ─────────────────────────────────────────────────────────
        if name == "__pycache__"   { return "Python bytecode cache — regenerated automatically" }
        if name == ".pytest_cache" { return "pytest test cache" }
        if name == ".mypy_cache"   { return "mypy type-checker cache" }
        if name == ".ruff_cache"   { return "ruff linter cache" }
        if name == ".hypothesis"   { return "Hypothesis property-testing database" }
        if name == ".tox"          { return "tox virtualenv cache" }

        // ── Gradle / Maven / JVM ───────────────────────────────────────────
        if path.hasPrefix("\(h)/.gradle/caches") || path.hasPrefix("\(h)/.gradle/wrapper") || path.hasPrefix("\(h)/.gradle/daemon") {
            return "Gradle cache — re-downloaded on next build"
        }
        if path.hasPrefix("\(h)/.m2/repository") {
            return "Maven local repository — re-downloaded on next build"
        }
        if path.hasPrefix("\(h)/.ivy2/cache") || path.hasPrefix("\(h)/.sbt") {
            return "SBT/Ivy dependency cache"
        }

        // ── Rust / Cargo ────────────────────────────────────────────────────
        // Only the download caches inside ~/.cargo are safe; not ~/.cargo/bin (installed tools)
        if path.hasPrefix("\(h)/.cargo/registry") {
            return "Cargo crate registry — re-downloaded on next build"
        }
        if path.hasPrefix("\(h)/.cargo/git") {
            return "Cargo git dependency cache"
        }

        // ── CocoaPods ───────────────────────────────────────────────────────
        if name == "Pods" && path.hasPrefix(h) {
            return "CocoaPods dependencies — restore with `pod install`"
        }
        if path.hasPrefix("\(h)/.cocoapods") {
            return "CocoaPods download cache"
        }

        // ── Frontend build tools ────────────────────────────────────────────
        if name == ".next"         { return "Next.js build output — regenerated on next build" }
        if name == ".nuxt"         { return "Nuxt.js build output" }
        if name == ".svelte-kit"   { return "SvelteKit build output" }
        if name == ".parcel-cache" { return "Parcel bundler cache" }
        if name == ".turbo"        { return "Turborepo pipeline cache" }
        if name == ".angular"      { return "Angular CLI cache" }
        if name == ".vercel"       { return "Vercel build cache" }

        return nil
    }
}
