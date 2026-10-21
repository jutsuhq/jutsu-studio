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
        #expect(AgentElementLookup.find("Mara Vance", in: all) == .ambiguous(count: 2))
        #expect(AgentElementLookup.find("roof", in: all) == .element(roof))
    }

    @Test func theElementsImagesComeFirstThenTheAgentsFilesEachWithItsTag() {
        let image = { (name: String) in LocalImage(fileURL: URL(fileURLWithPath: "/tmp/\(name).png")) }
        let references = AgentElementLookup.references(
            elements: [("Mara", [image("m1"), image("m2")]), ("Roof", [image("r1")])], files: [image("own")])
        #expect(references.map(\.tag) == ["@Image1", "@Image2", "@Image3", "@Image4"])
        #expect(references.map(\.element) == ["Mara", "Mara", "Roof", nil])
        #expect(references.map(\.image.fileURL.lastPathComponent) == ["m1.png", "m2.png", "r1.png", "own.png"])
        #expect(AgentElementLookup.references(elements: [], files: []).isEmpty)
    }
}
