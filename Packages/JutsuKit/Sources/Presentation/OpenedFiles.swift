import Foundation
import JutsuCore

/// What a file handed to the app by Finder's Open With or the Dock icon becomes in Create.
public enum OpenedFileKind: Sendable, Hashable {
    case video
    case image
    case unsupported

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "mts", "m2ts",
    ]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp",
    ]

    /// `conformsTo` answers whether the file conforms to a type identifier (`public.movie`, `public.image`),
    /// for files the extension tables don't know.
    public init(_ url: URL, conformsTo: (URL, String) -> Bool = { _, _ in false }) {
        let fileExtension = url.pathExtension.lowercased()
        if !url.isFileURL {
            self = .unsupported
        } else if Self.videoExtensions.contains(fileExtension) || conformsTo(url, "public.movie") {
            self = .video
        } else if Self.imageExtensions.contains(fileExtension) || conformsTo(url, "public.image") {
            self = .image
        } else {
            self = .unsupported
        }
    }
}

/// Opened files sorted for Create: one source video and the images for references.
public struct OpenRequest: Sendable, Hashable {
    /// Create has one source, so of several videos the last one opened wins.
    public private(set) var video: URL?
    public private(set) var images: [URL] = []
    public private(set) var unsupported: [URL] = []

    public init(_ urls: [URL], conformsTo: (URL, String) -> Bool = { _, _ in false }) {
        for url in urls {
            switch OpenedFileKind(url, conformsTo: conformsTo) {
            case .video: video = url
            case .image where !images.contains(url): images.append(url)
            case .image: break
            case .unsupported: unsupported.append(url)
            }
        }
    }

    public var isEmpty: Bool { video == nil && images.isEmpty && unsupported.isEmpty }

    /// Adds files opened after these, keeping the order they were opened in.
    public mutating func merge(_ later: OpenRequest) {
        video = later.video ?? video
        images += later.images.filter { !images.contains($0) }
        unsupported += later.unsupported
    }

    /// The alert for files Create can't use; `nil` when every file was a video or an image.
    public var unsupportedMessage: UserMessage? {
        guard let first = unsupported.first else { return nil }
        let title =
            unsupported.count == 1
            ? String(localized: "Can't open “\(first.lastPathComponent)”", bundle: .module)
            : String(localized: "Can't open \(unsupported.count) files", bundle: .module)
        return UserMessage(
            title: title, message: String(localized: "Jutsu Studio opens videos and images.", bundle: .module))
    }
}

/// Files opened before Create could take them, e.g. while the app was still launching or signed out.
/// Nothing is dropped: requests merge until `take()`.
public struct PendingOpens: Sendable, Hashable {
    private var request: OpenRequest?

    public init() {}

    public var isEmpty: Bool { request == nil }

    public mutating func add(_ new: OpenRequest) {
        guard !new.isEmpty else { return }
        if request == nil {
            request = new
        } else {
            request?.merge(new)
        }
    }

    /// Everything opened so far, oldest first; the queue is empty afterwards.
    public mutating func take() -> OpenRequest? {
        defer { request = nil }
        return request
    }
}

extension CreateForm {
    /// Adds opened images as references. The alert says how many didn't fit the mode's limit;
    /// images already added are skipped silently.
    public mutating func addOpenedReferences(_ images: [LocalImage]) -> UserMessage? {
        let left = images.count - addReferences(images)
        guard left > 0, !canAddReferences else { return nil }
        let limit = referenceLimits.upperBound
        let images = String(localized: "\(limit) reference images", bundle: .module)
        return UserMessage(
            title: String(localized: "\(left) images weren't added", bundle: .module),
            message: String(localized: "\(mode.title) takes up to \(images).", bundle: .module))
    }
}
