import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct LibrarySortAndModelTests {
    let items: [LibraryItemModel] = {
        var seedance = LibraryFixture.item(mode: .motionTransfer, source: "dance.mp4", cost: .usd(4, isEstimate: false))
        seedance.job.spec.model = .seedance25
        let credits = LibraryFixture.item(source: "credits.mov", cost: .credits(90, isEstimate: false), via: .account)
        let cheap = LibraryFixture.item(source: "cheap.mov", cost: .usd(1, isEstimate: false))
        let imported = LibraryItemModel(history: HistoryFixture.item("gen-1"))
        let sameAsCheap = LibraryFixture.item(source: "also-cheap.mov", cost: .usd(1, isEstimate: true))
        return [seedance, credits, cheap, imported, sameAsCheap]
    }()

    @Test func filtersByModel() {
        #expect(LibraryFilter(model: .seedance25).apply(items) == [items[0]])
        #expect(LibraryFilter(model: .klingMotionControl).apply(items).isEmpty)
        #expect(LibraryFilter(model: .genjutsu).apply(items) == [items[1], items[2], items[3], items[4]])
    }

    @Test func sortsNewestOrOldestFirst() {
        #expect(LibraryFilter(sort: .newest).apply(items) == items)
        #expect(LibraryFilter(sort: .oldest).apply(items) == items.reversed())
    }

    /// Dollars before credits, ties in their newest-first order, an unknown price last.
    @Test func sortsByHighestPrice() {
        #expect(LibraryFilter(sort: .highestPrice).apply(items) == [items[0], items[2], items[4], items[1], items[3]])
    }

    @Test func sortingFiltersOnlyWhatMatches() {
        #expect(
            LibraryFilter(model: .genjutsu, sort: .oldest).apply(items) == [items[4], items[3], items[2], items[1]])
    }

    @Test func orderIsNotAFilter() {
        #expect(!LibraryFilter(sort: .oldest).isActive)
        #expect(LibraryFilter(model: .seedance25).isActive)
        #expect(LibraryFilter(query: "x", model: .seedance25, sort: .oldest).cleared == LibraryFilter(sort: .oldest))
    }
}

@Suite struct LibrarySelectionTests {
    let batchID = UUID()
    let items: [LibraryItemModel]
    let entries: [LibraryEntry]

    init() {
        // A batch orders its results by creation time, so c is queued first here; a tie would fall back to the
        // random IDs and flip the batch's order between runs.
        var items = (0..<5).map {
            LibraryFixture.item(source: "clip\($0).mov", minutesAgo: Double($0), queuedMinutesAgo: $0 == 2 ? 61 : 60)
        }
        items[2].job.batchID = batchID
        items[3].job.batchID = batchID
        self.items = items
        // a, b, batch(c, d), e
        entries = LibraryEntry.group(items)
    }

    @Test func groupsTheFixtureIntoFourCards() {
        #expect(entries.count == 4)
        #expect(entries[2].itemIDs.count == 2)
    }

    @Test func commandClickTogglesACard() {
        var selection = LibrarySelection()
        selection.click(entries[1], .toggle, in: entries)
        #expect(selection.ids == [items[1].id])
        #expect(selection.contains(entries[1]))
        selection.click(entries[1], .toggle, in: entries)
        #expect(selection.isEmpty)
    }

    @Test func aBatchCardStandsForAllItsResults() {
        var selection = LibrarySelection()
        selection.click(entries[2], .toggle, in: entries)
        #expect(selection.ids == [items[2].id, items[3].id])
        #expect(selection.contains(entries[2]))
        #expect(LibraryBulkActions(selection.items(in: items)).items == [items[2], items[3]])
    }

    @Test func shiftClickAddsTheRangeFromTheLastToggledCard() {
        var selection = LibrarySelection()
        selection.click(entries[3], .toggle, in: entries)
        selection.click(entries[1], .extend, in: entries)
        #expect(selection.ids == Set(items[1...4].map(\.id)))
        #expect(!selection.contains(entries[0]))
    }

    @Test func shiftClickWithoutAnAnchorToggles() {
        var selection = LibrarySelection()
        selection.click(entries[0], .extend, in: entries)
        #expect(selection.ids == [items[0].id])
    }

    @Test func togglingTheAnchorOffDropsIt() {
        var selection = LibrarySelection()
        selection.click(entries[0], .toggle, in: entries)
        selection.click(entries[0], .toggle, in: entries)
        selection.click(entries[3], .extend, in: entries)
        #expect(selection.ids == [items[4].id])
    }

    @Test func selectAllAndClear() {
        var selection = LibrarySelection()
        selection.selectAll(entries)
        #expect(selection.ids == Set(items.map(\.id)))
        #expect(entries.allSatisfy(selection.contains))
        selection.clear()
        #expect(selection.isEmpty)
        #expect(selection.anchor == nil)
    }

    @Test func actsOnlyOnTheResultsShown() {
        var selection = LibrarySelection()
        selection.selectAll(entries)
        #expect(selection.items(in: [items[4], items[0]]) == [items[4], items[0]])
    }

    @Test func anUnselectedCardDragsItsOwnResults() {
        var selection = LibrarySelection()
        selection.click(entries[0], .toggle, in: entries)
        selection.click(entries[1], .toggle, in: entries)
        #expect(selection.dragged(entries[3], in: items) == [items[4]])
        #expect(selection.dragged(entries[2], in: items) == [items[2], items[3]])
    }

    @Test func aCardSelectedWithOthersDragsTheWholeSelection() {
        var selection = LibrarySelection()
        selection.click(entries[0], .toggle, in: entries)
        selection.click(entries[2], .toggle, in: entries)
        #expect(selection.dragged(entries[0], in: items) == [items[0], items[2], items[3]])
        #expect(selection.dragged(entries[2], in: items) == [items[0], items[2], items[3]])
        #expect(selection.bulkItems(around: entries[1], in: items) == nil)
    }

    /// A card selected alone acts alone; a batch card is several results but still one card.
    @Test func aCardSelectedAloneIsNotABulkSelection() {
        var selection = LibrarySelection()
        selection.click(entries[2], .toggle, in: entries)
        #expect(selection.bulkItems(around: entries[2], in: items) == nil)
        #expect(selection.dragged(entries[2], in: items) == [items[2], items[3]])
    }

    /// Results without a downloaded file, and selected ones the filters hide, aren't dragged; a card without a
    /// downloaded file can't be dragged even among selected ones that have one.
    @Test func dragsOnlyDownloadedFilesShown() {
        var items = self.items
        items[1].job.outputFile = nil
        let remote = LibraryItemModel(history: HistoryFixture.item("gen-1"))
        let shown = items + [remote]
        let entries = LibraryEntry.group(shown)
        var selection = LibrarySelection()
        selection.selectAll(entries)
        #expect(selection.dragged(entries[0], in: shown) == [items[0], items[2], items[3], items[4]])
        #expect(selection.dragged(entries[0], in: [items[0], items[4]]) == [items[0], items[4]])
        #expect(selection.dragged(entries[1], in: shown).isEmpty)
        #expect(selection.dragged(.item(remote), in: shown).isEmpty)
    }
}

@Suite struct LibraryBulkActionsTests {
    @Test func countsAndFiles() {
        var starred = LibraryFixture.item(source: "a.mov")
        starred.isStarred = true
        var noFile = LibraryFixture.item(source: "b.mov")
        noFile.job.outputFile = nil
        let remote = LibraryItemModel(history: HistoryFixture.item("gen-1"))
        let bulk = LibraryBulkActions([starred, noFile, remote])
        #expect(bulk.title == "3 selected")
        #expect(bulk.deletable == [starred, noFile])
        #expect(bulk.files == [URL(fileURLWithPath: "/Users/me/Movies/Jutsu Studio/out.mp4")])
    }

    @Test func starsAllUnlessEveryOneIsStarred() {
        var starred = LibraryFixture.item()
        starred.isStarred = true
        #expect(LibraryBulkActions.starsAll([starred, LibraryFixture.item()]))
        #expect(!LibraryBulkActions.starsAll([starred, starred]))
    }

    @Test func deleteConfirmationNamesTheCount() {
        #expect(LibraryDeleteConfirmation.title(count: 1) == "Delete from library?")
        #expect(LibraryDeleteConfirmation.title(count: 3) == "Delete 3 results from library?")
        #expect(LibraryDeleteConfirmation.message(count: 1) == LibraryDeleteConfirmation.message)
        #expect(
            LibraryDeleteConfirmation.message(count: 2)
                == "The video files move to the Trash and their history entries are removed.")
    }

    @Test func batchDeletesOnlyTheUnstarred() throws {
        let id = UUID()
        var kept = LibraryFixture.item(source: "a.mov")
        kept.isStarred = true
        kept.job.batchID = id
        var lost = LibraryFixture.item(source: "b.mov")
        lost.job.batchID = id
        let batch = try #require(LibraryBatch(id: id, in: [kept, lost]))
        #expect(batch.unstarred.map(\.id) == [lost.id])
    }
}
