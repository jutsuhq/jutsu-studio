import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct ComparePairTests {
    private func withoutFile(_ item: LibraryItemModel) -> LibraryItemModel {
        var item = item
        item.job.outputFile = nil
        return item
    }

    @Test func needsTwoDifferentResultsOnDisk() {
        let draft = LibraryFixture.item(resolution: .p480, isDraft: true)
        let final = LibraryFixture.item(resolution: .p720, isDraft: false)
        #expect(ComparePair(draft, final) != nil)
        #expect(ComparePair(draft, draft) == nil)
        #expect(ComparePair(draft, withoutFile(final)) == nil)
    }

    @Test func tracksAreLabelledWithTheSettingsChipsLeftFirst() throws {
        let draft = LibraryFixture.item(resolution: .p480, isDraft: true, presetName: "Claymation")
        let final = LibraryFixture.item(resolution: .p1080, isDraft: false, presetName: "Film Noir")
        let pair = try #require(ComparePair(draft, final))

        #expect(pair.tracks.map(\.id.itemID) == [draft.id, final.id])
        #expect(pair.tracks.map(\.labels) == [draft.facts, final.facts])
        #expect(pair.tracks.first?.labels == ["Restyle", "Claymation", "480p", "6 s"])
        #expect(pair.tracks.allSatisfy { !$0.isSource && $0.clip.range == nil })
    }

    @Test func swappingTwiceRestoresTheSides() throws {
        let left = LibraryFixture.item(resolution: .p480)
        let right = LibraryFixture.item(resolution: .p720)
        var pair = try #require(ComparePair(left, right))

        pair.swap()
        #expect(pair.left.id == right.id)
        #expect(pair.right.id == left.id)
        #expect(pair.tracks.map(\.id.itemID) == [right.id, left.id])
        pair.swap()
        #expect(pair.left.id == left.id)
    }

    @Test func candidatesPutTheSameSourceFirstAndSkipTheItemAndMissingFiles() {
        let item = LibraryFixture.item(source: "rooftop.mov")
        let other = LibraryFixture.item(source: "dance.mp4")
        let sibling = LibraryFixture.item(source: "rooftop.mov", resolution: .p720, isDraft: false)
        let missing = withoutFile(LibraryFixture.item(source: "rooftop.mov"))
        let library = [other, item, missing, sibling]

        #expect(ComparePair.candidates(for: item, in: library).map(\.id) == [sibling.id, other.id])
        #expect(ComparePair.candidates(for: item, in: library, limit: 1).map(\.id) == [sibling.id])
        #expect(ComparePair.candidates(for: item, in: [item]).isEmpty)
    }

    @Test func menuTitleNamesTheResolutionAndKind() {
        let draft = LibraryFixture.item(resolution: .p480, isDraft: true, presetName: "Claymation")
        let final = LibraryFixture.item(resolution: .p1080, isDraft: false, presetName: "Claymation")
        #expect(ComparePair.menuTitle(for: draft) == "rooftop · Claymation — 480p draft")
        #expect(ComparePair.menuTitle(for: final) == "rooftop · Claymation — 1080p final")
    }
}

@Suite struct ComparePickerTests {
    @Test func pairsTheTwoPicksInOrder() throws {
        let first = LibraryFixture.item(resolution: .p480)
        let second = LibraryFixture.item(resolution: .p720)
        var picker = ComparePicker()
        #expect(picker.prompt == "Pick two results to compare")

        picker.toggle(second.id)
        #expect(picker.prompt == "Pick one more")
        #expect(picker.pair(in: [first, second]) == nil)
        picker.toggle(first.id)

        #expect(picker.prompt == "Ready to compare")
        let pair = try #require(picker.pair(in: [first, second]))
        #expect(pair.left.id == second.id)
        #expect(pair.right.id == first.id)
    }

    @Test func togglingAPickRemovesIt() {
        let id = UUID()
        var picker = ComparePicker()
        picker.toggle(id)
        #expect(picker.isPicked(id))
        picker.toggle(id)
        #expect(!picker.isPicked(id))
        #expect(picker.picked.isEmpty)
    }

    @Test func aThirdPickReplacesTheOldest() {
        let ids = [UUID(), UUID(), UUID()]
        var picker = ComparePicker()
        for id in ids { picker.toggle(id) }
        #expect(picker.picked == [ids[1], ids[2]])
    }

    @Test func noPairWhileAPickIsGoneFromTheLibrary() {
        let kept = LibraryFixture.item()
        var picker = ComparePicker()
        picker.toggle(kept.id)
        picker.toggle(UUID())
        #expect(picker.pair(in: [kept]) == nil)
    }
}

@Suite struct CompareLayoutTests {
    @Test func dividerOnlyForTwo() {
        #expect(CompareLayout.available(forTrackCount: 2) == [.sideBySide, .divider])
        #expect(CompareLayout.available(forTrackCount: 1) == [.sideBySide])
        #expect(CompareLayout.available(forTrackCount: 4) == [.sideBySide])
    }

    @Test func oneRowUpToThreeThenSquare() {
        #expect(CompareLayout.columns(forTrackCount: 0) == 1)
        #expect(CompareLayout.columns(forTrackCount: 2) == 2)
        #expect(CompareLayout.columns(forTrackCount: 3) == 3)
        #expect(CompareLayout.columns(forTrackCount: 4) == 2)
        #expect(CompareLayout.columns(forTrackCount: 6) == 3)
        #expect(CompareLayout.columns(forTrackCount: 9) == 3)
    }

    @Test func sourceTrackFollowsTheRangeItWasMadeFrom() throws {
        let item = LibraryFixture.item(range: 4...10)
        let source = try #require(CompareTrack.source(item))
        #expect(source.isSource)
        #expect(source.clip.range == 4...10)
        #expect(source.labels == ["Source"])
    }
}

@Suite struct CompareTimelineTests {
    @Test func runsToTheShortestKnownResult() {
        #expect(CompareTimeline.duration(of: [6.2, 5.04]) == 5.04)
        #expect(CompareTimeline.duration(of: [nil, 6]) == 6)
        #expect(CompareTimeline.duration(of: [.nan, 0, 4]) == 4)
    }

    @Test func zeroUntilADurationIsKnown() {
        #expect(CompareTimeline.duration(of: []) == 0)
        #expect(CompareTimeline.duration(of: [nil, .infinity]) == 0)
    }
}
