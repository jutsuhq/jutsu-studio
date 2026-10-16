import Foundation
import JutsuCore

/// The account's history as the library pages through it: newest first, in memory only, for one account at a time.
public struct AccountHistory: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case idle
        case loading
        /// The last load failed; the items loaded before stay.
        case failed(UserMessage)
    }

    /// One load to run: the first page on a refresh, else the page at `cursor`.
    public struct Request: Sendable, Hashable {
        public var owner: String?
        public var cursor: HistoryCursor?
        public var isRefresh: Bool
        fileprivate var token: Int
    }

    /// Pages in a row that may add nothing before loading stops until the user asks for more.
    static let maxEmptyPagesInARow = 5

    public private(set) var owner: String?
    public private(set) var items: [HistoryItem] = []
    /// Finished image generations, newest first within their stream; the grid interleaves them with `items` by date.
    public private(set) var images: [HistoryImageItem] = []
    public private(set) var phase = Phase.idle
    public private(set) var nextCursor: HistoryCursor?
    /// The first page has arrived since the last reset.
    public private(set) var hasLoaded = false
    /// Library item IDs by remote ID, so an item keeps its ID across refreshes.
    private var jobIDs: [String: UUID] = [:]
    private var token = 0
    private var emptyPagesInARow = 0

    public init(owner: String? = nil) {
        self.owner = owner
    }

    /// Another account, or none, starts from an empty history; the same account keeps it.
    public mutating func switchAccount(to owner: String?) {
        guard owner != self.owner else { return }
        let next = token + 1
        self = AccountHistory(owner: owner)
        token = next
    }

    /// There may be pages after the loaded ones.
    public var hasMore: Bool { !hasLoaded || nextCursor != nil }

    public var isLoading: Bool { phase == .loading }

    /// Loading stopped after too many pages that added nothing; more may follow when the user asks.
    public var isWaitingToLoadMore: Bool {
        phase == .idle && nextCursor != nil && emptyPagesInARow >= Self.maxEmptyPagesInARow
    }

    /// What the grid's "load more" task follows: the counts of both streams and the packed cursor, so a page
    /// of only images still asks for the next one while either stream has more.
    public struct PagingProgress: Sendable, Hashable {
        public var videos: Int
        public var images: Int
        public var cursor: HistoryCursor?
    }

    public var pagingProgress: PagingProgress {
        PagingProgress(videos: items.count, images: images.count, cursor: nextCursor)
    }

    /// Starts a load, or returns `nil` when none should start: a page is already loading, or there are no more.
    /// A refresh always starts and wins over a load in flight.
    public mutating func beginLoad(refresh: Bool) -> Request? {
        if !refresh, phase == .loading { return nil }
        let isRefresh = refresh || !hasLoaded
        if !isRefresh, nextCursor == nil { return nil }
        token += 1
        phase = .loading
        // Past the limit only the user starts a load, which counts the empty pages afresh.
        if isRefresh || emptyPagesInARow >= Self.maxEmptyPagesInARow { emptyPagesInARow = 0 }
        return Request(owner: owner, cursor: isRefresh ? nil : nextCursor, isRefresh: isRefresh, token: token)
    }

    /// Applies the page `request` asked for; answers to a superseded request are dropped. Returns `true` when
    /// the page added nothing but more may follow, so the next one should load right away.
    @discardableResult
    public mutating func receive(_ page: HistoryPage, for request: Request) -> Bool {
        guard request.token == token, request.owner == owner else { return false }
        let before = request.isRefresh ? 0 : items.count + images.count
        var known = request.isRefresh ? [] : items
        var seen = Set(known.map(\.id))
        for var item in page.items where seen.insert(item.id).inserted {
            item.jobID = jobIDs[item.id] ?? item.jobID
            jobIDs[item.id] = item.jobID
            known.append(item)
        }
        items = known
        var knownImages = request.isRefresh ? [] : images
        var seenImages = Set(knownImages.map(\.id))
        for var image in page.images where seenImages.insert(image.id).inserted {
            image.jobID = jobIDs[image.id] ?? image.jobID
            jobIDs[image.id] = image.jobID
            knownImages.append(image)
        }
        images = knownImages
        let added = items.count + images.count - before
        nextCursor = page.nextCursor
        hasLoaded = true
        phase = .idle
        emptyPagesInARow = added == 0 ? emptyPagesInARow + 1 : 0
        return added == 0 && nextCursor != nil && emptyPagesInARow < Self.maxEmptyPagesInARow
    }

    /// Records a like set from the app, so the history agrees with the star until it is loaded again.
    public mutating func setLiked(_ id: String, _ isLiked: Bool) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].isLiked = isLiked }
        if let index = images.firstIndex(where: { $0.id == id }) { images[index].isLiked = isLiked }
    }

    public mutating func fail(_ error: any Error, for request: Request) {
        guard request.token == token, request.owner == owner else { return }
        let message =
            UserMessage(error, kind: .account)
            ?? UserMessage(
                title: String(localized: "Can't load your Higgsfield history", bundle: .module),
                message: String(localized: "Try again in a moment.", bundle: .module))
        phase = error is CancellationError ? .idle : .failed(message)
    }
}

/// Whether the active connection can show the account's history, and what to say when it can't.
public enum HistoryAvailability: Sendable, Hashable {
    case available
    case unavailable(title: String, detail: String)

    public init(_ connection: ConnectionState) {
        switch connection {
        case .account:
            self = .available
        case .apiKey:
            self = .unavailable(
                title: String(localized: "History needs a Higgsfield account", bundle: .module),
                detail: String(
                    localized:
                        "An API key can't read past generations. Sign in to your account in Settings to see them.",
                    bundle: .module))
        case .none:
            self = .unavailable(
                title: String(localized: "Sign in to see your Higgsfield history", bundle: .module),
                detail: String(
                    localized: "Videos made on higgsfield.ai appear here once you sign in to your account in Settings.",
                    bundle: .module))
        }
    }

    public static let emptyTitle = String(localized: "No videos on Higgsfield yet", bundle: .module)
    public static let emptyDetail =
        String(
            localized: "Finished Motion and Swap videos from Genjutsu, Kling and Seedance on your account appear here.",
            bundle: .module) + " " + stylesNote
    /// Neither `show_generations` nor `show_marketing_studio_generations` returns a finished Style job (live run,
    /// 2026-10-15, issue #21), so only the Styles the app started itself, which its own job store keeps, are known.
    public static let stylesNote = String(
        localized: "Styles made outside Jutsu Studio aren't listed: Higgsfield's history doesn't return them.",
        bundle: .module)
}

/// What the Higgsfield source shows instead of the grid.
public enum HistoryPlaceholder: Sendable, Hashable {
    /// Why this connection has no history.
    case unavailable(title: String, detail: String)
    /// The first load failed; offers a retry.
    case failed(UserMessage)
    /// The first load is running.
    case loading
    /// The account has no history.
    case empty

    /// `nil` once there are items to show. `isEmpty`: the source has no items, before filters.
    public init?(availability: HistoryAvailability, history: AccountHistory, isEmpty: Bool) {
        if case .unavailable(let title, let detail) = availability {
            self = .unavailable(title: title, detail: detail)
            return
        }
        guard isEmpty else { return nil }
        if case .failed(let message) = history.phase {
            self = .failed(message)
        } else if !history.hasLoaded || history.isLoading {
            self = .loading
        } else {
            self = .empty
        }
    }
}

/// Where the library's videos come from: this Mac, or the Higgsfield account.
public enum LibraryOrigin: String, Sendable, Hashable, CaseIterable, Identifiable {
    case local
    case higgsfield

    public var id: Self { self }

    public var title: String {
        switch self {
        case .local: String(localized: "On this Mac", bundle: .module)
        case .higgsfield: String(localized: "From Higgsfield", bundle: .module)
        }
    }
}
