import Foundation

/// Local names for files the provider serves: each name safe as one path component, the extension from
/// an allowlist, and the result checked to stay inside its folder.
public enum ServerFileName {
    public static let videoExtensions = ["mp4", "mov"]
    public static let imageExtensions = ["jpg", "jpeg", "png", "heic", "webp"]

    /// `folder/<names[0]>/…/<names.last>.<ext>`, where `ext` is `url`'s extension when `allowed` holds it and
    /// otherwise the first of `allowed`. `nil` when the path would leave `folder`.
    public static func file(in folder: URL, named names: [String], extensionOf url: URL, allowed: [String]) -> URL? {
        guard let last = names.last, let fallbackExtension = allowed.first else { return nil }
        var file = folder
        for name in names.dropLast() {
            file.appendPathComponent(component(name), isDirectory: true)
        }
        let given = url.pathExtension.lowercased()
        let fileExtension = allowed.contains(given) ? given : fallbackExtension
        file.appendPathComponent("\(component(last)).\(fileExtension)", isDirectory: false)
        return isInside(file, folder) ? file : nil
    }

    /// `name` as one path component: no separators, no leading dots, never empty.
    static func component(_ name: String) -> String {
        let sanitized = OutputNamePattern.sanitize(name.replacingOccurrences(of: "\\", with: "-"))
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    static func isInside(_ file: URL, _ folder: URL) -> Bool {
        let root = folder.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return file.standardizedFileURL.path.hasPrefix(prefix)
    }
}
