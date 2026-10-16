import AppKit

/// The way back to the app from a browser: the URL scheme in Info.plist (`APP_URL_SCHEME` in project.yml).
enum AppLink {
    static let scheme: String? = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first
    }()

    static var url: URL? { scheme.flatMap { URL(string: "\($0)://") } }

    static func isAppLink(_ url: URL) -> Bool {
        guard let scheme else { return false }
        return url.scheme?.lowercased() == scheme.lowercased()
    }

    /// The app icon as a PNG `side` pixels square, for a web page.
    @MainActor static func iconPNG(side: CGFloat = 192) -> Data? {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = NSApp.applicationIconImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
