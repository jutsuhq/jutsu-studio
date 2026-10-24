import Foundation

/// An image made with Generate…, saved in the output folder's `Images` folder (`OutputSubfolder.images`) as soon as it is ready. Library ›
/// Images lists them; the file is the image, and this keeps what made it.
public struct SavedImage: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var fileURL: URL
    public var prompt: String
    /// The image model's name, e.g. "Higgsfield Soul 2.0".
    public var model: String
    /// "16:9"; `nil` when unknown.
    public var aspectRatio: String?
    public var createdAt: Date
    /// Where the provider served it; its links expire, so it isn't read again.
    public var remoteURL: URL?
    /// The catalog star, projected into the image card.
    public var isStarred = false
    /// An agent's name for it (`MaterialGeneration.title`), which the card shows instead of the prompt.
    public var title: String?

    public init(
        id: UUID = UUID(), fileURL: URL, prompt: String, model: String, aspectRatio: String?, createdAt: Date,
        remoteURL: URL? = nil, isStarred: Bool = false, title: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.prompt = prompt
        self.model = model
        self.aspectRatio = aspectRatio
        self.createdAt = createdAt
        self.remoteURL = remoteURL
        self.isStarred = isStarred
        self.title = title
    }

    /// "2026-10-15 10.41.03 A knight in silver armor", without the extension: the date first, so the files sort
    /// by when they were made, then the start of the prompt.
    public static func baseName(prompt: String, createdAt: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: createdAt)
        let date = String(
            format: "%04d-%02d-%02d %02d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let words = prompt.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : title + " " + word
            if next.count > maxTitleLength { break }
            title = next
        }
        // No path separators, colons or leading dots: the name stays one Finder-safe component.
        let safe = title.map { "/:\\".contains($0) ? "-" : $0 }.drop { $0 == "." }
        return safe.isEmpty ? date : date + " " + String(safe)
    }

    static let maxTitleLength = 48
}

/// An image that was made, and paid for, but isn't saved into the library yet. Kept until it is, so a download that
/// fails or a quit doesn't lose it while the provider's link still serves it.
public struct PendingImage: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var remoteURL: URL
    public var prompt: String
    public var model: String
    public var aspectRatio: String?
    public var createdAt: Date
    public var remote: MaterialRemote?
    public var parameters: Data?
    public var inputImages: [LocalImage] = []
    public var variantGroupID: UUID?
    public var title: String?

    public init(id: UUID, remoteURL: URL, prompt: String, model: String, aspectRatio: String?, createdAt: Date) {
        self.id = id
        self.remoteURL = remoteURL
        self.prompt = prompt
        self.model = model
        self.aspectRatio = aspectRatio
        self.createdAt = createdAt
    }

    /// How long the provider serves a result, so how long saving it again is worth trying.
    public static let lifetime: TimeInterval = 7 * 24 * 3600
}
