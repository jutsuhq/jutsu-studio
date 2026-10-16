import Foundation

/// A provider whose account likes its generations; the library's star follows the like.
public protocol GenerationLikes: Sendable {
    /// Sets the like of the generation `RemoteJob.requestID` names; setting the state it has is harmless.
    func setLiked(_ requestID: String, _ isLiked: Bool) async throws
}

/// A provider that reports the account's credit movements.
public protocol CreditHistory: Sendable {
    /// One page, newest first; `nil` for the first page.
    func creditHistory(after cursor: HistoryCursor?) async throws -> CreditPage
}

/// A provider whose account keeps the files uploaded to it, to start new jobs from.
public protocol AccountUploads: Sendable {
    /// One page of `kind`, newest first; `nil` for the first page.
    func uploads(_ kind: UploadKind, after cursor: HistoryCursor?) async throws -> UploadPage
}

/// One movement of the account's credits. The provider names no job, only what the credits were for.
public struct CreditEntry: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case spend
        case refund
        case grant
        case deduct
        case other
    }

    public var date: Date
    /// Negative when spent, positive when refunded or granted.
    public var credits: Double
    public var kind: Kind
    /// "Higgsfield Genjutsu - Object Swap".
    public var title: String

    public init(date: Date, credits: Double, kind: Kind, title: String) {
        self.date = date
        self.credits = credits
        self.kind = kind
        self.title = title
    }
}

public struct CreditPage: Sendable, Hashable {
    public var items: [CreditEntry]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [CreditEntry], nextCursor: HistoryCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum UploadKind: String, Sendable, Hashable, CaseIterable {
    case image
    case video
}

/// A file the account uploaded, downloadable while the provider keeps it.
public struct UploadedFile: Sendable, Hashable, Identifiable {
    /// The provider's media ID.
    public var id: String
    public var kind: UploadKind
    public var url: URL
    /// Videos only.
    public var thumbnailURL: URL?
    public var pixelSize: PixelSize?
    /// Videos only, in seconds.
    public var duration: TimeInterval?
    public var createdAt: Date

    public init(
        id: String, kind: UploadKind, url: URL, thumbnailURL: URL? = nil, pixelSize: PixelSize? = nil,
        duration: TimeInterval? = nil, createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.pixelSize = pixelSize
        self.duration = duration
        self.createdAt = createdAt
    }
}

public struct UploadPage: Sendable, Hashable {
    public var items: [UploadedFile]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [UploadedFile], nextCursor: HistoryCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
