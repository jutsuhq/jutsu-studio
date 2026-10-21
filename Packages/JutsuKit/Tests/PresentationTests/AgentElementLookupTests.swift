import Foundation
import JutsuCore
import Testing

@testable import Presentation

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
