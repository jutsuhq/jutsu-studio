import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Elements a page at a time, recording the cursors asked for.
private struct PagedElements: AccountElements {
    let pages: [AccountElementPage]
    let asked = Box<[HistoryCursor?]>([])

    var owner: String? { "user_1" }

    func elements(after cursor: HistoryCursor?) async throws -> AccountElementPage {
        asked.update { $0.append(cursor) }
        return pages[asked.value.count - 1]
    }

    func elementImages(_ element: AccountElement) async throws -> AccountElement { element }

    func createElement(name: String, category: ElementCategory, images: [RemoteAsset]) async throws -> AccountElement {
        AccountElement(id: "el-new", name: name, category: category)
    }
}

/// The account's elements as agents name them.
@Suite struct AgentElementLookupTests {
    let mara = AccountElement(id: "el-1", name: "Mara Vance", category: .character)
    let roof = AccountElement(id: "el-2", name: "Roof", category: .environment)

    @Test func everyWordOfTheQueryIsInTheNameInAnyCase() {
        #expect(AgentElementLookup.matches(mara, query: "vance MARA", category: nil))
        #expect(AgentElementLookup.matches(mara, query: "", category: .character))
        #expect(!AgentElementLookup.matches(mara, query: "mara", category: .prop))
        #expect(!AgentElementLookup.matches(roof, query: "mara", category: nil))
    }

    @Test func aNameIsFoundWholeInAnyCaseAndTwoOfItAreAmbiguous() {
        #expect(AgentElementLookup.find(" mara vance", in: [roof, mara]) == .element(mara))
        #expect(AgentElementLookup.find("Mara", in: [roof, mara]) == .missing)
        var twin = mara
        twin.id = "el-3"
        #expect(AgentElementLookup.find("Mara Vance", in: [mara, twin]) == .ambiguous(count: 2))
    }

    /// A twin on a later page still makes the name ambiguous: every page is read before a name is decided.
    @Test func everyPageIsReadSoATwinOnALaterPageIsFound() async throws {
        var twin = mara
        twin.id = "el-3"
        let pages = [
            AccountElementPage(items: [mara], nextCursor: HistoryCursor("2")),
            AccountElementPage(items: [roof], nextCursor: HistoryCursor("3")),
            AccountElementPage(items: [twin], nextCursor: nil),
        ]
        let source = PagedElements(pages: pages)
        let all = try await AgentElementLookup.all(in: source)
        #expect(source.asked.value == [nil, HistoryCursor("2"), HistoryCursor("3")])
        #expect(all.isComplete)
        #expect(AgentElementLookup.find("Mara Vance", in: all.elements) == .ambiguous(count: 2))
        #expect(AgentElementLookup.find("roof", in: all.elements) == .element(roof))
    }

    /// A page of `elements` holds at most `limit`; one that ends inside a page of the account's hands out a cursor
    /// into it, and the next page starts with the element after.
    @Test func aPageHoldsAtMostTheLimitAndGoesOnWhereItStopped() async throws {
        var twin = mara
        twin.id = "el-3"
        let pages = [
            AccountElementPage(items: [roof], nextCursor: HistoryCursor("3")),
            AccountElementPage(items: [mara, roof, twin], nextCursor: HistoryCursor("4")),
            AccountElementPage(items: [mara], nextCursor: nil),
        ]
        // The fake answers page after page whatever the cursor: the second call reads the middle page again.
        let source = PagedElements(pages: [pages[0], pages[1], pages[1], pages[2]])
        let first = try await AgentElementLookup.page(
            in: source, query: "mara", category: nil, limit: 1, after: "2")
        #expect(first.items == [mara])
        #expect(source.asked.value == [HistoryCursor("2"), HistoryCursor("3")])
        let cursor = try #require(first.nextCursor)

        let second = try await AgentElementLookup.page(
            in: source, query: "mara", category: nil, limit: 1, after: cursor)
        #expect(second.items == [twin])
        // The page's last element: the cursor is the account's next page.
        #expect(second.nextCursor == "4")
        #expect(source.asked.value.last == HistoryCursor("3"))

        let rest = try await AgentElementLookup.page(
            in: source, query: "mara", category: nil, limit: 5, after: second.nextCursor)
        #expect(rest.items == [mara])
        #expect(rest.nextCursor == nil)
    }

    /// A query that matches nothing stops after `maxPages`, with the cursor to go on from; looking a name up in that
    /// many pages can't tell one element of it from two, so it is unchecked.
    @Test func aLookupStopsAfterMaxPages() async throws {
        let pages = (1...45).map { AccountElementPage(items: [roof], nextCursor: HistoryCursor("\($0 + 1)")) }
        let source = PagedElements(pages: pages)
        let page = try await AgentElementLookup.page(in: source, query: "mara", category: nil, limit: 5, after: nil)
        #expect(page.items.isEmpty)
        #expect(source.asked.value.count == AgentElementLookup.maxPages)
        #expect(page.nextCursor == "\(AgentElementLookup.maxPages + 1)")

        let all = try await AgentElementLookup.all(in: source)
        #expect(!all.isComplete)
        #expect(AgentElementLookup.find("roof", in: all.elements, isComplete: all.isComplete) == .ambiguous(count: 20))
        #expect(AgentElementLookup.find("Mara Vance", in: all.elements, isComplete: false) == .unchecked)
        #expect(AgentElementLookup.find("Mara Vance", in: [mara], isComplete: false) == .unchecked)
    }

    @Test func theElementsImagesComeFirstThenTheAgentsFilesEachWithItsTag() {
        let image = { (name: String) in LocalImage(fileURL: URL(fileURLWithPath: "/tmp/\(name).png")) }
        let references = AgentElementLookup.references(
            elements: [
                AgentElementLookup.ElementImages(name: "Mara", images: [image("m1"), image("m2")]),
                AgentElementLookup.ElementImages(name: "Roof", images: [image("r1")]),
            ], files: [image("own")])
        #expect(references.map(\.tag) == ["@Image1", "@Image2", "@Image3", "@Image4"])
        #expect(references.map(\.element) == ["Mara", "Mara", "Roof", nil])
        #expect(references.map(\.image.fileURL.lastPathComponent) == ["m1.png", "m2.png", "r1.png", "own.png"])
        #expect(AgentElementLookup.references(elements: [], files: []).isEmpty)
    }
}
