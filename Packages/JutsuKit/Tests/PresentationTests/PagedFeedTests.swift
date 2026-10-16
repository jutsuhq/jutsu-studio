import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

@MainActor
@Suite struct PagedFeedTests {
    struct Row: Identifiable, Sendable, Hashable {
        var id: Int
    }

    /// Answers each call with the next scripted page.
    final class Pages: @unchecked Sendable {
        // Safe: only touched on the main actor by the tests and the feed's fetch.
        var answers: [Result<([Row], HistoryCursor?), any Error>]
        var cursors: [HistoryCursor?] = []

        init(_ answers: [Result<([Row], HistoryCursor?), any Error>]) {
            self.answers = answers
        }

        func next(_ cursor: HistoryCursor?) throws -> PagedFeed<Row>.Page {
            cursors.append(cursor)
            let (items, next) = try answers.removeFirst().get()
            return (items, next)
        }
    }

    static func feed(_ pages: Pages) -> PagedFeed<Row> {
        PagedFeed(failureTitle: "Can't load") { cursor in try await MainActor.run { try pages.next(cursor) } }
    }

    @Test func pagesFollowTheCursorUntilTheLastOne() async {
        let pages = Pages([
            .success(([Row(id: 1), Row(id: 2)], HistoryCursor("2"))), .success(([Row(id: 3)], nil)),
        ])
        let feed = Self.feed(pages)

        await feed.loadIfNeeded()
        await feed.loadIfNeeded()
        #expect(feed.items.map(\.id) == [1, 2] && feed.hasMore)
        await feed.loadMore()
        await feed.loadMore()

        #expect(feed.items.map(\.id) == [1, 2, 3])
        #expect(!feed.hasMore)
        #expect(pages.cursors == [nil, HistoryCursor("2")])
    }

    @Test func aPageThatRepeatsEverythingEndsTheFeed() async {
        let pages = Pages([.success(([Row(id: 1)], HistoryCursor("a"))), .success(([Row(id: 1)], HistoryCursor("b")))])
        let feed = Self.feed(pages)

        await feed.loadMore()
        await feed.loadMore()

        #expect(feed.items.map(\.id) == [1])
        #expect(!feed.hasMore)
    }

    @Test func aFailureKeepsTheItemsAndRefreshStartsOver() async {
        let pages = Pages([
            .success(([Row(id: 1)], HistoryCursor("a"))), .failure(ProviderError.network),
            .success(([Row(id: 9)], nil)),
        ])
        let feed = Self.feed(pages)

        await feed.loadMore()
        await feed.loadMore()
        #expect(feed.items.map(\.id) == [1])
        #expect(feed.failure?.title == "Can't reach Higgsfield")

        await feed.refresh()
        #expect(feed.items.map(\.id) == [9])
        #expect(feed.failure == nil && !feed.hasMore)
        #expect(pages.cursors == [nil, HistoryCursor("a"), nil])
    }

    @Test func aCancelledCallerDoesNotCancelTheLoad() async {
        let gate = Gate<Void>()
        let feed = PagedFeed<Row>(failureTitle: "Can't load") { _ in
            try await gate.wait()
            try Task.checkCancellation()
            return ([Row(id: 1)], nil)
        }
        let caller = Task { await feed.loadIfNeeded() }
        await eventually { await gate.isWaiting }
        caller.cancel()
        await gate.open(.success(()))
        await caller.value
        #expect(feed.items == [Row(id: 1)])
        #expect(feed.failure == nil && !feed.isLoading)
    }

    @Test func creditAmountsReadSigned() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(CreditEntry(date: date, credits: -45, kind: .spend, title: "").amountText == "−45")
        #expect(CreditEntry(date: date, credits: 39, kind: .refund, title: "").amountText == "+39")
        #expect(CreditEntry(date: date, credits: -54.41, kind: .spend, title: "").amountText == "−54.41")
        #expect(CreditEntry(date: date, credits: 0, kind: .spend, title: "").amountText == "0")
        #expect(CreditEntry(date: date, credits: 39, kind: .refund, title: "").kindTitle == "Refunded")
    }
}
