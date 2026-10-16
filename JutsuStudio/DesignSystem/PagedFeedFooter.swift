import Presentation
import SwiftUI

/// The end of a list read page by page (`PagedFeed`): a failed page's title with Try Again, else a spinner that loads
/// the next page once it is scrolled into view, else nothing. Place it after the items in a lazy stack, so it appears,
/// and loads, only when scrolled to.
struct PagedFeedFooter: View {
    let failure: UserMessage?
    let hasMore: Bool
    /// How many items are shown; each new count lets the spinner ask for the next page again.
    let count: Int
    /// The spinner stands for a first page that something else already shows, such as skeleton tiles.
    var hidesSpinner = false
    let loadMore: @MainActor () async -> Void

    var body: some View {
        if let failure {
            HStack(spacing: Theme.Spacing.small) {
                Text(failure.title).foregroundStyle(Theme.muted)
                Button("Try Again") { Task { await loadMore() } }
                    .buttonStyle(.secondaryAction)
            }
            .padding(.top, Theme.Spacing.large)
        } else if hasMore {
            ProgressView()
                .controlSize(.small)
                .opacity(hidesSpinner ? 0 : 1)
                .padding(.top, Theme.Spacing.large)
                .task(id: count) { await loadMore() }
        }
    }
}

extension PagedFeedFooter {
    init<Item>(_ feed: PagedFeed<Item>) {
        self.init(failure: feed.failure, hasMore: feed.hasMore, count: feed.items.count) { await feed.loadMore() }
    }
}
