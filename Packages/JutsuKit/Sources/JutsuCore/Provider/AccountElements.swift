import Foundation

/// A provider whose account keeps reusable references: named elements (characters, environments, props), each with
/// images that can be used as reference images.
public protocol AccountElements: Sendable {
    /// `GenerationProvider.owner` of the account the elements belong to.
    var owner: String? { get }
    /// One page of the elements, in the provider's order; `nil` for the first page.
    func elements(after cursor: HistoryCursor?) async throws -> AccountElementPage
    /// `element` with all its images, for one whose page named none.
    func elementImages(_ element: AccountElement) async throws -> AccountElement
    /// Publishes `images`, uploads of this account (`GenerationProvider.upload`), as a new element named `name`.
    /// Free. Not idempotent: sent again, it makes a second element.
    func createElement(name: String, category: ElementCategory, images: [RemoteAsset]) async throws -> AccountElement
}

/// What an element shows.
public enum ElementCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case character
    case environment
    case prop

    public var id: Self { self }
}

/// A reference element of the account.
public struct AccountElement: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// `nil` when the provider didn't say.
    public var category: ElementCategory?
    public var thumbnailURL: URL?
    public var images: [ElementImage]
    /// The provider's state of it, such as `completed` once it can be used or `processing` while it is checked;
    /// `nil` when the provider didn't say. Lists hold only usable ones.
    public var status: String?

    public init(
        id: String, name: String, category: ElementCategory? = nil, thumbnailURL: URL? = nil,
        images: [ElementImage] = [], status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.thumbnailURL = thumbnailURL
        self.images = images
        self.status = status
    }
}

/// One image of an element: its file on the provider and, when the provider named it, the media it already is.
public struct ElementImage: Sendable, Hashable, Identifiable {
    public var url: URL
    /// Sent instead of an upload of the downloaded file; `nil` when the provider named no media ID.
    public var media: ServerMedia?

    public init(url: URL, media: ServerMedia? = nil) {
        self.url = url
        self.media = media
    }

    public var id: URL { url }
}

public struct AccountElementPage: Sendable, Hashable {
    public var items: [AccountElement]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [AccountElement], nextCursor: HistoryCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A file the provider already keeps for one account, named by its media ID (an upload's, or a finished image job's
/// such as a character sheet): a job of that account sends the ID instead of uploading the file again.
public struct ServerMedia: Codable, Sendable, Hashable {
    public var id: String
    public var url: URL
    /// `GenerationProvider.owner` of the account that listed it; another account's job uploads the file instead.
    public var owner: String?

    public init(id: String, url: URL, owner: String?) {
        self.id = id
        self.url = url
        self.owner = owner
    }
}
