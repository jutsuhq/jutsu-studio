import Foundation
import JutsuCore
import Observation

/// The Motion Library's shelves as the Create screen browses them: each is a `PagedFeed` that loads on first view
/// and pages on demand.
@MainActor
@Observable
public final class MotionLibraryModel {
    public var shelf = MotionShelf.featured

    @ObservationIgnored private let feeds: [MotionShelf: PagedFeed<MotionPreset>]

    public init(library: any MotionLibrary) {
        var feeds: [MotionShelf: PagedFeed<MotionPreset>] = [:]
        for shelf in MotionShelf.allCases {
            feeds[shelf] = PagedFeed(failureTitle: String(localized: "Can't load the library", bundle: .module)) {
                cursor in
                let page = try await library.motionPresets(on: shelf, after: cursor)
                return (page.items, page.nextCursor)
            }
        }
        self.feeds = feeds
    }

    public var current: [MotionPreset] { feed?.items ?? [] }
    public var isLoading: Bool { feed?.isLoading ?? false }
    public var failure: UserMessage? { feed?.failure }
    public var hasMore: Bool { feed?.hasMore ?? false }

    /// Loads the shown shelf's first page, unless it has one.
    public func loadIfNeeded() async {
        await feed?.loadIfNeeded()
    }

    /// The shown shelf's next page. Ignored after its last page; joins the load already running for it.
    /// The request runs on its own task, so a caller that is cancelled, like a view's `.task` whose ID changed
    /// when loading began, doesn't cancel it.
    public func loadMore() async {
        await feed?.loadMore()
    }

    private var feed: PagedFeed<MotionPreset>? { feeds[shelf] }
}
