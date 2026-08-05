import SwiftUI

enum FileTypeIcon {
    static func systemName(for node: FileNode) -> String {
        node.isDirectory ? "folder.fill" : systemName(forExt: node.fileExtension)
    }

    static func systemName(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "bmp", "webp", "svg":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm":
            return "film"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx", "pages", "rtf", "txt", "md":
            return "doc.text"
        case "xls", "xlsx", "numbers":
            return "tablecells"
        case "ppt", "pptx", "key":
            return "rectangle.on.rectangle"
        case "zip", "gz", "tar", "bz2", "7z", "rar", "xz", "lz4":
            return "archivebox"
        case "dmg", "img", "iso", "sparseimage", "raw", "vmdk", "vhd", "vhdx":
            return "opticaldisc"
        case "app", "ipa":
            return "app"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "java", "kt", "m", "mm":
            return "curlybraces"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "sh", "bash", "zsh", "fish", "command":
            return "terminal"
        case "sql", "db", "sqlite", "sqlite3":
            return "cylinder"
        case "ttf", "otf", "woff", "woff2":
            return "textformat"
        case "dylib", "so", "a":
            return "puzzlepiece.extension"
        case "framework", "xcframework":
            return "shippingbox"
        case "data", "pack", "index", "bin":
            return "doc.zipper"
        default:
            return "doc"
        }
    }

    static func color(for node: FileNode) -> Color {
        node.isDirectory ? .yellow : color(forExt: node.fileExtension)
    }

    static func color(forExt ext: String) -> Color {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "bmp", "webp", "svg":
            return .blue
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm":
            return .purple
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff":
            return .pink
        case "pdf":
            return .red
        case "doc", "docx", "pages", "rtf", "txt", "md":
            return .blue
        case "xls", "xlsx", "numbers":
            return .green
        case "zip", "gz", "tar", "bz2", "7z", "rar", "xz", "lz4":
            return .orange
        case "dmg", "img", "iso", "sparseimage", "raw", "vmdk", "vhd":
            return Color(nsColor: .systemGray)
        case "app", "ipa":
            return .accentColor
        case "swift", "py", "js", "ts", "rb", "go", "rs", "c", "cpp", "h", "java", "kt", "m", "mm":
            return .mint
        case "sql", "db", "sqlite", "sqlite3":
            return .cyan
        case "dylib", "so", "a", "framework", "xcframework":
            return .teal
        default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }
}
