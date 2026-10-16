import Foundation
import JutsuCore
import Observation

/// The account's reference elements as References › From Higgsfield browses them: one `PagedFeed`, kept for the
/// connection like the Motion Library's, loaded on first view and paged on demand. Elements whose calls aren't
/// confirmed are never fetched.
@MainActor
@Observable
public final class AccountElementsModel {
    /// `nil` shows every category.
    public var category: ElementCategory?

    @ObservationIgnored private let source: any AccountElements
    @ObservationIgnored private let feed: PagedFeed<AccountElement>?

    /// - Parameter isOffered: whether the provider is known to take the calls
    ///   (`HiggsfieldMCPProvider.offersReferenceElements`).
    public init(source: any AccountElements, isOffered: Bool) {
        self.source = source
        feed =
            isOffered
            ? PagedFeed(failureTitle: String(localized: "Can't load your elements", bundle: .module)) { cursor in
                let page = try await source.elements(after: cursor)
                return (page.items, page.nextCursor)
            } : nil
    }

    /// Why the elements can't be browsed; `nil` when they can.
    public var unavailableReason: String? {
        feed == nil ? PostOperationText.waitingForCatalog : nil
    }

    /// The elements, filtered by `category`.
    public var current: [AccountElement] {
        let items = feed?.items ?? []
        guard let category else { return items }
        return items.filter { $0.category == category }
    }

    public var hasLoaded: Bool { feed?.hasLoaded ?? false }
    public var isLoading: Bool { feed?.isLoading ?? false }
    public var failure: UserMessage? { feed?.failure }
    public var hasMore: Bool { feed?.hasMore ?? false }

    public func loadIfNeeded() async {
        await feed?.loadIfNeeded()
    }

    public func loadMore() async {
        await feed?.loadMore()
    }

    /// Whether a character set can be published as an element ("Save to Higgsfield…").
    public var canPublish: Bool { feed != nil }

    /// Uploads `images` with `upload`, in order, and publishes them as a new character element named `name`, which
    /// is then offered first in the list. Free. Sent once: a failure after the call may have reached the server can
    /// still have made the element, which the list shows on its next load.
    public func publish(
        _ images: [LocalImage], name: String, upload: (LocalImage) async throws -> RemoteAsset
    ) async throws -> SavedElement {
        guard canPublish else {
            throw ProviderError.validation(field: nil, message: PostOperationText.waitingForCatalog)
        }
        var assets: [RemoteAsset] = []
        for image in images {
            try Task.checkCancellation()
            assets.append(try await upload(image))
        }
        try Task.checkCancellation()
        let element = try await source.createElement(
            name: SavedElement.name(name), category: .character, images: assets)
        feed?.insert(element)
        return SavedElement(id: element.id, owner: source.owner)
    }

    /// `element` with its images, asking the provider when its page named none.
    public func withImages(_ element: AccountElement) async throws -> AccountElement {
        guard element.images.isEmpty, feed != nil else { return element }
        return try await source.elementImages(element)
    }
}

/// A character set published to an account as a reference element, so it isn't published twice.
public struct SavedElement: Codable, Sendable, Hashable {
    public var id: String
    /// `GenerationProvider.owner` of the account it was published to.
    public var owner: String?

    public init(id: String, owner: String?) {
        self.id = id
        self.owner = owner
    }

    /// The most characters an element's name takes ("max 32 chars").
    public static let nameLimit = 32

    /// `name` without surrounding spaces, cut to `nameLimit`.
    public static func name(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Save to Higgsfield…".
    public static let saveTitle = String(localized: "Save to Higgsfield…", bundle: .module)
    /// Shown on a set once it is published.
    public static let savedTitle = String(localized: "Saved to Higgsfield", bundle: .module)
    /// The dialog's explanation: what saving does and that it is free.
    public static func saveExplanation(imageCount: Int) -> String {
        String(
            localized:
                "Uploads \(imageCount) images and saves them as a character element on your Higgsfield account, for References › From Higgsfield and the web app. Free, no credits are spent.",
            bundle: .module)
    }
    /// The title of a failed save.
    public static let failureTitle = String(localized: "Can't save to Higgsfield", bundle: .module)

    /// What a failed save tells the user, in the words of the account's errors under `failureTitle`; one that leads
    /// somewhere (sign in again) keeps its own title. `nil` when the save was cancelled.
    public static func failure(_ error: any Error) -> UserMessage? {
        guard var message = UserMessage(error, kind: .account) else { return nil }
        if message.action == nil { message.title = failureTitle }
        return message
    }
}

/// What picking an element does with its images, given how many more references the form takes.
public enum ElementPick: Sendable, Hashable {
    /// Every image fits: they are added in the element's order.
    case add([ElementImage])
    /// More images than fit: the user picks up to `limit`, starting from the first ones.
    case choose([ElementImage], limit: Int)
    /// Nothing can be added: the element has no images, or the form is full.
    case unavailable(String)

    public static func of(_ element: AccountElement, limit: Int) -> ElementPick {
        if element.images.isEmpty {
            return .unavailable(String(localized: "This element has no images to use.", bundle: .module))
        }
        if limit <= 0 {
            return .unavailable(String(localized: "References are full.", bundle: .module))
        }
        return element.images.count <= limit ? .add(element.images) : .choose(element.images, limit: limit)
    }
}

extension ElementCategory {
    /// "Character", "Environment", "Prop".
    public var title: String {
        switch self {
        case .character: String(localized: "Character", bundle: .module)
        case .environment: String(localized: "Environment", bundle: .module)
        case .prop: String(localized: "Prop", bundle: .module)
        }
    }
}
