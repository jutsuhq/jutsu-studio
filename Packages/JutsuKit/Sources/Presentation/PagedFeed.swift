import Foundation
import JutsuCore
import Observation

/// A list the provider hands out page by page, newest first: the credit history, the account's uploads. The first
/// page loads on first view, the next ones on demand.
@MainActor
@Observable
public final class PagedFeed<Item: Identifiable & Sendable> where Item.ID: Sendable {
    public typealias Page = (items: [Item], next: HistoryCursor?)

    public private(set) var items: [Item] = []
    public private(set) var isLoading = false
    /// The last failure; cleared by the next page that arrives.
    public private(set) var failure: UserMessage?
    /// The first page has arrived.
    public private(set) var hasLoaded = false

    @ObservationIgnored private let fetch: @Sendable (HistoryCursor?) async throws -> Page
    @ObservationIgnored private let failureTitle: String
    @ObservationIgnored private var cursor: HistoryCursor?
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// - Parameter failureTitle: what a failed page says when the error has no message of its own.
    public init(failureTitle: String, fetch: @escaping @Sendable (HistoryCursor?) async throws -> Page) {
        self.failureTitle = failureTitle
        self.fetch = fetch
    }

    public var hasMore: Bool { !finished }

    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await loadMore()
    }

    /// The next page; ignored after the last one, and joins the load already running. The request runs on its
    /// own task, so a caller that is cancelled, like a view's `.task`, doesn't cancel it.
    public func loadMore() async {
        if let running = inFlight {
            await running.value
            return
        }
        guard !finished else { return }
        let load = Task { await fetchPage() }
        inFlight = load
        await load.value
    }

    /// Starts over from the first page; a page still loading is dropped.
    public func refresh() async {
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        cursor = nil
        finished = false
        hasLoaded = false
        failure = nil
        await loadMore()
        if !hasLoaded { items = [] }
    }

    /// Puts `item` first, as the newest, in place of an item with its ID. Ignored before the first page arrives,
    /// which brings it from the provider.
    public func insert(_ item: Item) {
        guard hasLoaded else { return }
        items = [item] + items.filter { $0.id != item.id }
    }

    private func fetchPage() async {
        let started = generation
        isLoading = true
        defer {
            if started == generation {
                isLoading = false
                inFlight = nil
            }
        }
        do {
            let page = try await fetch(cursor)
            guard started == generation else { return }
            let known = Set((hasLoaded ? items : []).map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) }
            items = (hasLoaded ? items : []) + fresh
            hasLoaded = true
            // A next page that repeats what is shown is the end too.
            if let next = page.next, !fresh.isEmpty { cursor = next } else { finished = true }
            failure = nil
        } catch {
            guard started == generation, !(error is CancellationError) else { return }
            failure =
                UserMessage(error, kind: .account)
                ?? UserMessage(title: failureTitle, message: String(localized: "Try again.", bundle: .module))
        }
    }
}

extension CreditEntry: Identifiable {
    /// The provider names no ID; the time, amount and title tell entries apart.
    public var id: String { "\(date.timeIntervalSince1970)|\(credits)|\(title)" }

    /// "−45", "+39", "0".
    public var amountText: String {
        let magnitude = (abs(credits) * 100).rounded() / 100
        let number = magnitude == magnitude.rounded() ? String(Int(magnitude)) : "\(magnitude)"
        if credits < 0 { return "−" + number }
        return credits > 0 ? "+" + number : number
    }

    /// "Spent", "Refunded": the kind, for the row's detail.
    public var kindTitle: String {
        switch kind {
        case .spend: String(localized: "Spent", bundle: .module)
        case .refund: String(localized: "Refunded", bundle: .module)
        case .grant: String(localized: "Added", bundle: .module)
        case .deduct: String(localized: "Deducted", bundle: .module)
        case .other: String(localized: "Other", bundle: .module)
        }
    }
}
