import Foundation
import JutsuCore

/// A link Create is downloading, shown with its progress and a Cancel button in the section it goes to.
public struct LinkDownload: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var link: URL
    /// The kind of input asked for: `.video` from the Source section, `.image` from References, `nil` from ⌘V.
    public var expected: MediaLink.Kind?
    /// 0…1; `nil` while the size is unknown.
    public var fraction: Double?

    public init(link: URL, expected: MediaLink.Kind?, fraction: Double? = nil, id: UUID = UUID()) {
        self.id = id
        self.link = link
        self.expected = expected
        self.fraction = fraction
    }

    /// Whether the section for `kind` shows it; a ⌘V download shows in the Source section.
    public func shows(in kind: MediaLink.Kind) -> Bool { (expected ?? .video) == kind }

    /// "Downloading from example.com… 42%".
    public var text: String {
        let host = link.host ?? link.absoluteString
        guard let fraction else { return String(localized: "Downloading from \(host)…", bundle: .module) }
        let percent = CostText.percent(Int((fraction * 100).rounded(.down)))
        return String(localized: "Downloading from \(host)… \(percent)", bundle: .module)
    }

    /// The Paste URL field's title and placeholder.
    public static func prompt(for kind: MediaLink.Kind) -> String {
        switch kind {
        case .video: String(localized: "Paste a link to a video", bundle: .module)
        case .image: String(localized: "Paste a link to an image", bundle: .module)
        }
    }

    public static let placeholder = "https://"
    public static let explanation = String(
        localized: "A direct link to the file, starting with https://. Jutsu Studio downloads it first.",
        bundle: .module)
}

extension UserMessage {
    /// The alert for a link that couldn't be used.
    public init(_ error: MediaLinkError) {
        let title = String(localized: "Can't use this link", bundle: .module)
        switch error {
        case .notALink:
            self.init(
                title: title,
                message: String(localized: "Paste a web address that starts with https://.", bundle: .module))
        case .notHTTPS:
            self.init(
                title: title,
                message: String(
                    localized: "Only secure links (https://) are downloaded. Try the same address with https.",
                    bundle: .module))
        case .notMedia:
            self.init(
                title: String(localized: "This link isn't a video or an image", bundle: .module),
                message: String(
                    localized: """
                        It leads to a web page or another kind of file. Use a direct link to the file, such as one \
                        ending in .mp4 or .jpg; pages like a YouTube video can't be downloaded.
                        """, bundle: .module))
        case .wrongKind(.video):
            self.init(
                title: String(localized: "This link isn't a video", bundle: .module),
                message: String(localized: "Add images under references instead.", bundle: .module))
        case .wrongKind(.image):
            self.init(
                title: String(localized: "This link isn't an image", bundle: .module),
                message: String(localized: "Add videos as the source instead.", bundle: .module))
        case .tooLarge(let maxBytes):
            let limit = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
            self.init(
                title: String(localized: "The file is too large", bundle: .module),
                message: String(
                    localized: "Links to files over \(limit) aren't downloaded. Trim the video first.",
                    bundle: .module))
        case .unavailable(let status):
            self = Self.unavailable(status)
        case .network:
            self.init(
                title: String(localized: "Can't download the file", bundle: .module),
                message: String(localized: "Check your internet connection and try again.", bundle: .module))
        case .notEnoughSpace:
            self.init(
                title: String(localized: "Not enough disk space", bundle: .module),
                message: String(localized: "Free up space on your Mac and try again.", bundle: .module))
        }
    }

    /// A server that refused the file: 401 and 403 are hotlink protection or a bot check (Cloudflare's challenge
    /// answers 403 to anything but a browser), so the way round is saving the file in a browser.
    private static func unavailable(_ status: Int) -> UserMessage {
        guard status == 401 || status == 403 else {
            return UserMessage(
                title: String(localized: "Can't download the file", bundle: .module),
                message: String(
                    localized: "The server answered \(status). Check that the link opens in a browser.",
                    bundle: .module))
        }
        return UserMessage(
            title: String(localized: "The site doesn't let the app download this file", bundle: .module),
            message: String(
                localized: """
                    The server answered \(status): it gives the file only to a browser. Open the link in a \
                    browser, save the file, then drop it on the window.
                    """, bundle: .module))
    }
}
