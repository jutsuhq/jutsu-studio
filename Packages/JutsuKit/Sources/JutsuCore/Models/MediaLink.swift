import Foundation

/// A web link to a video or image that Create downloads and uses like a picked file.
public enum MediaLink {
    public enum Kind: String, Codable, Sendable, Hashable {
        case video
        case image
    }

    /// The link in pasted or typed text: one `https:` URL with a host, surrounding spaces ignored.
    public static func parse(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed), let scheme = url.scheme?.lowercased()
        else { throw MediaLinkError.notALink }
        guard scheme == "https" else {
            throw scheme == "http" ? MediaLinkError.notHTTPS : MediaLinkError.notALink
        }
        guard url.host?.isEmpty == false else { throw MediaLinkError.notALink }
        return url
    }

    /// What a download is, from its `Content-Type`, and the extension its file gets. A generic binary type (or none)
    /// falls back to the extension of `url`, so a storage host that labels everything `application/octet-stream`
    /// still works. Pages (`text/html`, e.g. a YouTube watch page) and anything else are refused.
    public static func classify(contentType: String?, url: URL) throws -> (kind: Kind, fileExtension: String) {
        let mime = mimeType(of: contentType)
        if let known = mimeTypes[mime] { return known }
        let pathExtension = url.pathExtension.lowercased()
        let byExtension = extensionKinds[pathExtension].map { (kind: $0, fileExtension: pathExtension) }
        if let byExtension, genericTypes.contains(mime) || mime.hasPrefix("\(byExtension.kind.rawValue)/") {
            return byExtension
        }
        throw MediaLinkError.notMedia(contentType: mime.isEmpty ? nil : mime)
    }

    /// Refuses a download whose `Content-Type` says it isn't an image, like `classify`, but takes any `image/` type and
    /// leaves a generic binary type (or none) to the decoder: for a picture that is only shown, never kept or sent.
    public static func checkImage(contentType: String?) throws {
        let mime = mimeType(of: contentType)
        guard mime.hasPrefix("image/") || genericTypes.contains(mime) else {
            throw MediaLinkError.notMedia(contentType: mime)
        }
    }

    /// The media type of a `Content-Type` header, without its parameters and lowercased; "" for none.
    private static func mimeType(of contentType: String?) -> String {
        contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }

    /// The downloaded file's name: the link's last path component without its extension, or its host.
    public static func baseName(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name != "/" else { return url.host ?? "Download" }
        return name
    }

    static let genericTypes: Set<String> = ["", "application/octet-stream", "binary/octet-stream"]

    static let mimeTypes: [String: (kind: Kind, fileExtension: String)] = [
        "video/mp4": (.video, "mp4"), "video/quicktime": (.video, "mov"), "video/x-m4v": (.video, "m4v"),
        "video/webm": (.video, "webm"), "video/x-matroska": (.video, "mkv"), "video/mpeg": (.video, "mpg"),
        "video/3gpp": (.video, "3gp"), "image/jpeg": (.image, "jpg"), "image/jpg": (.image, "jpg"),
        "image/png": (.image, "png"), "image/webp": (.image, "webp"), "image/gif": (.image, "gif"),
        "image/heic": (.image, "heic"), "image/heif": (.image, "heif"), "image/tiff": (.image, "tiff"),
        "image/bmp": (.image, "bmp"),
    ]

    static let extensionKinds: [String: Kind] = [
        "mp4": .video, "mov": .video, "m4v": .video, "webm": .video, "mkv": .video, "mpg": .video, "mpeg": .video,
        "3gp": .video, "jpg": .image, "jpeg": .image, "png": .image, "webp": .image, "gif": .image, "heic": .image,
        "heif": .image, "tif": .image, "tiff": .image, "bmp": .image,
    ]

    /// Files a provider can take by link as they are, without the local conversion an upload goes through: the
    /// REST API's input types (`video/mp4`; JPEG, PNG, WebP, GIF).
    static let linkableExtensions: [Kind: Set<String>] = [
        .video: ["mp4"], .image: ["jpg", "jpeg", "png", "webp", "gif"],
    ]

    static func isLinkable(_ file: URL, as kind: Kind) -> Bool {
        linkableExtensions[kind]?.contains(file.pathExtension.lowercased()) == true
    }
}

public enum MediaLinkError: Error, Sendable, Hashable {
    /// The text isn't a web address.
    case notALink
    /// `http:` or another scheme: only `https:` is downloaded.
    case notHTTPS
    /// The link leads to a page or a file that isn't a video or image.
    case notMedia(contentType: String?)
    /// A video where an image was asked for, or the other way round.
    case wrongKind(expected: MediaLink.Kind)
    case tooLarge(maxBytes: Int64)
    /// The server answered with this status.
    case unavailable(status: Int)
    case network
    case notEnoughSpace
}

extension SourceClip {
    /// The link the file was downloaded from while the job sends the file exactly as downloaded: the whole of it,
    /// not upscaled, in a type a provider takes by link. `nil` when the clip has to be prepared and uploaded.
    public var linkableOrigin: URL? {
        guard let remoteOrigin, fileURL.isFileURL, MediaLink.isLinkable(fileURL, as: .video) else { return nil }
        let tolerance = 0.01
        let isWhole = range.lowerBound <= tolerance && range.upperBound >= duration - tolerance
        let isUpscaled =
            allowsUpscale && Validation.upscaledSize(width: pixelSize.width, height: pixelSize.height) != pixelSize
        return isWhole && !isUpscaled ? remoteOrigin : nil
    }
}

extension LocalImage {
    /// The link the image was downloaded from, when a provider can take the file by link as it is.
    public var linkableOrigin: URL? {
        guard let remoteOrigin, fileURL.isFileURL, MediaLink.isLinkable(fileURL, as: .image) else { return nil }
        return remoteOrigin
    }
}
