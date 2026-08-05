import SwiftUI

public struct ExtensionColorMap: Equatable, Sendable {

    // ── Semantic palette — vivid, dark-mode optimised ───────────────────────
    static let palette: [Color] = [
        Color(hue: 0.08, saturation: 0.90, brightness: 1.00), // 0 orange   — video
        Color(hue: 0.35, saturation: 0.82, brightness: 0.92), // 1 emerald  — images
        Color(hue: 0.52, saturation: 0.88, brightness: 1.00), // 2 cyan     — audio
        Color(hue: 0.62, saturation: 0.85, brightness: 1.00), // 3 blue     — code
        Color(hue: 0.75, saturation: 0.68, brightness: 0.98), // 4 violet   — docs
        Color(hue: 0.01, saturation: 0.85, brightness: 0.95), // 5 red      — archives
        Color(hue: 0.13, saturation: 0.90, brightness: 1.00), // 6 yellow   — data / config
        Color(hue: 0.47, saturation: 0.75, brightness: 0.88), // 7 teal     — web
        Color(hue: 0.90, saturation: 0.62, brightness: 0.98), // 8 pink     — fonts
        Color(hue: 0.25, saturation: 0.82, brightness: 0.90), // 9 lime     — 3D / models
    ]

    private static let extIndex: [String: Int] = {
        var m: [String: Int] = [:]
        for e in ["mp4","mov","avi","mkv","m4v","wmv","flv","webm","ts","mts","m2ts","vob","3gp"] { m[e] = 0 }
        for e in ["jpg","jpeg","png","gif","heic","heif","tiff","tif","bmp","webp","svg","ico","raw","cr2","nef","arw","dng","psd","ai","eps"] { m[e] = 1 }
        for e in ["mp3","aac","wav","flac","m4a","ogg","aiff","aif","opus","alac","wma","mid","midi"] { m[e] = 2 }
        for e in ["swift","py","js","ts","jsx","tsx","go","rs","cpp","c","java","kt","rb","php","cs","h","hh","m","mm","sh","bash","zsh","fish","pl","lua","r","scala","vue","elm","ex","exs","clj","hs","ml","nim","zig","dart","sol","v","jai","odin"] { m[e] = 3 }
        for e in ["pdf","doc","docx","pages","txt","md","rtf","epub","odt","numbers","xlsx","xls","ppt","pptx","key","tex","rst","adoc"] { m[e] = 4 }
        for e in ["zip","tar","gz","bz2","xz","rar","7z","dmg","pkg","xip","deb","rpm","iso","ipa","apk","cab","lzma","zst"] { m[e] = 5 }
        for e in ["json","xml","yaml","yml","toml","ini","conf","sqlite","db","sql","plist","proto","graphql","env","lock","ndjson"] { m[e] = 6 }
        for e in ["html","htm","css","scss","less","sass","wasm","vue"] { m[e] = 7 }
        for e in ["ttf","otf","woff","woff2","eot","pfb","pfm","fon"] { m[e] = 8 }
        for e in ["obj","fbx","blend","stl","gltf","glb","dae","abc","usd","usda","usdc","usdz","scn","reality","3ds","ply","step"] { m[e] = 9 }
        return m
    }()

    let scheme: String

    public init(root: FileNode) {
        self.scheme = UserDefaults.standard.string(forKey: "treemapColorScheme") ?? "byType"
    }

    public func color(for fileExtension: String) -> Color {
        let lower = fileExtension.lowercased()
        switch scheme {
        case "monochrome":
            let hash = lower.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
            let brightness = 0.52 + Double(hash % 36) / 100.0
            return Color(hue: 0.62, saturation: lower.isEmpty ? 0.05 : 0.28, brightness: brightness)
        case "rainbow":
            let hash = lower.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
            let hue = Double(hash % 360) / 360.0
            return Color(hue: hue, saturation: 0.88, brightness: 0.96)
        default:
            if let idx = Self.extIndex[lower] { return Self.palette[idx] }
            let hash = lower.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
            let hue = Double(hash % 360) / 360.0
            return Color(hue: hue, saturation: 0.58, brightness: 0.88)
        }
    }

    public static func == (lhs: ExtensionColorMap, rhs: ExtensionColorMap) -> Bool {
        lhs.scheme == rhs.scheme
    }
}
