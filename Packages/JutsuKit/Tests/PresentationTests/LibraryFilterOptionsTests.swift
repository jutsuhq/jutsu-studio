import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct LibraryFilterOptionsTests {
    let options = LibraryFilterOptions(LibraryMediaFixture.rows())

    @Test func menusListOnlyTheValuesTheRowsHave() {
        #expect(Set(options.modes) == [.motionTransfer, .restyle])
        #expect(options.resolutions == [.p480, .p720])
        #expect(options.hasDraftsAndFinals)
        #expect(options.imageModels == ["Higgsfield Soul 2.0", "soul-2.0"])
    }

    @Test func aMenuWithOneValueIsLeftOutUnlessItHoldsOne() {
        let filter = LibraryFilter()
        #expect(options.models.count == 1)
        #expect(!options.shows(.model, in: filter))
        #expect(options.shows(.model, in: LibraryFilter(model: options.models[0])))
        #expect(options.shows(.mode, in: filter))
        #expect(options.shows(.finish, in: filter))
        #expect(options.shows(.starred, in: filter))
    }

    @Test func finishNeedsBothDraftsAndFinals() {
        let drafts = LibraryFilterOptions([.video(LibraryFixture.item(isDraft: true))])
        #expect(!drafts.shows(.finish, in: LibraryFilter()))
        #expect(drafts.shows(.finish, in: LibraryFilter(finish: .finals)))
    }
}
