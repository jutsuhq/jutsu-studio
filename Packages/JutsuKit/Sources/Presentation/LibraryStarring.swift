import Foundation
import JutsuCore

/// Where a result's star is kept. The app sets it on the result's `MaterialRecord`; failed writes are reported.
@MainActor
public protocol LibraryStarStore {
    /// Stars or unstars the result with `id`; nothing for a result without a record.
    func setStarred(_ isStarred: Bool, for id: UUID) throws
}

/// The library's star, which is also the result's like on Higgsfield when the connected account ran the job or has
/// it in its history.
public struct LibraryStarring {
    /// The connection's likes; `nil` while disconnected or with an API key.
    let likes: (any GenerationLikes)?
    /// `GenerationProvider.owner` of the connection.
    let owner: String?

    public init(likes: (any GenerationLikes)?, owner: String?) {
        self.likes = likes
        self.owner = owner
    }

    /// Whether starring the item also likes it on the connected account: the account ran the job, or it is in
    /// the account's history.
    public func syncsLike(_ item: LibraryItemModel) -> Bool {
        guard item.likeID != nil, likes != nil else { return false }
        return item.historyItem != nil || item.job.owner == owner
    }

    /// Whether the star of a result can change here: a local result, or one in the account's history whose like
    /// it follows.
    public func canStar(_ item: LibraryItemModel) -> Bool {
        item.historyItem == nil || syncsLike(item)
    }

    /// Stars or unstars a result and likes or unlikes it on Higgsfield to match. The local star is set at once and
    /// put back if Higgsfield refuses; the error is rethrown.
    /// - Parameter liked: called with each like Higgsfield took, for the account's history.
    @MainActor
    public func setStarred(
        _ isStarred: Bool, for item: LibraryItemModel, in store: any LibraryStarStore,
        liked: (_ id: String, _ isLiked: Bool) -> Void
    ) async throws {
        try store.setStarred(isStarred, for: item.id)
        guard syncsLike(item), let id = item.likeID, let likes else { return }
        do {
            try await likes.setLiked(id, isStarred)
            liked(id, isStarred)
        } catch {
            try store.setStarred(!isStarred, for: item.id)
            throw error
        }
    }

    /// Stars or unstars each result that isn't so already, one after the other, as `setStarred(_:for:in:liked:)`
    /// does for one. The first like Higgsfield refuses stops the rest and is rethrown.
    @MainActor
    public func setStarred(
        _ isStarred: Bool, _ items: [LibraryItemModel], in store: any LibraryStarStore,
        liked: (_ id: String, _ isLiked: Bool) -> Void
    ) async throws {
        for item in items where item.isStarred != isStarred {
            try await setStarred(isStarred, for: item, in: store, liked: liked)
        }
    }
}

extension UserMessage {
    /// For a like Higgsfield refused, after the star was put back.
    public static func likeNotSaved(_ error: any Error) -> UserMessage {
        UserMessage(error, kind: .account)
            ?? UserMessage(
                title: String(localized: "Can't update the like on Higgsfield", bundle: .module),
                message: String(localized: "The star is back as it was. Try again.", bundle: .module))
    }
}

/// Wording for the star, which is also the result's like on Higgsfield when the account made it.
public enum LibraryStar {
    public static func help(isStarred: Bool, syncsLike: Bool) -> String {
        switch (isStarred, syncsLike) {
        case (true, true): String(localized: "Unstar, and remove the like on Higgsfield", bundle: .module)
        case (true, false): String(localized: "Unstar", bundle: .module)
        case (false, true):
            String(localized: "Star to find it with the Starred filter; it is liked on Higgsfield too", bundle: .module)
        case (false, false): String(localized: "Star to find it with the Starred filter", bundle: .module)
        }
    }
}
