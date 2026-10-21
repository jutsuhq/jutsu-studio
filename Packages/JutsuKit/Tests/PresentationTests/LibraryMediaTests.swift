import Foundation
import JutsuCore
import Testing

@testable import Presentation

enum LibraryMediaFixture {
    static let now = LibraryFixture.now

    static func image(
        prompt: String = "A knight in silver armor", model: String = "Higgsfield Soul 2.0",
        aspectRatio: String? = "16:9", minutesAgo: Double = 10, isStarred: Bool = false
    ) -> SavedImage {
        SavedImage(
            fileURL: URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/Images/knight.png"), prompt: prompt,
            model: model, aspectRatio: aspectRatio, createdAt: now.addingTimeInterval(-minutesAgo * 60),
            remoteURL: URL(string: "https://cdn.example.com/knight.png")!, isStarred: isStarred)
    }

    static func remoteImage(
        _ id: String, prompt: String = "Neon dance", model: String = "soul-2.0",
        minutesAgo: Double = 20, isLiked: Bool = false
    ) -> HistoryImageItem {
        HistoryImageItem(
            id: id, prompt: prompt, model: model, createdAt: now.addingTimeInterval(-minutesAgo * 60),
            isLiked: isLiked, outputURL: HistoryFixture.url("\(id).png"),
            pixelSize: PixelSize(width: 1024, height: 1024))
    }

    static func rows() -> [LibraryMediaItem] {
        [
            .video(LibraryFixture.item(mode: .restyle, resolution: .p480, isDraft: true, minutesAgo: 36)),
            .video(
                LibraryFixture.item(
                    mode: .motionTransfer, source: "dance.mp4", resolution: .p720, isDraft: false,
                    prompt: "Keep the camera move", minutesAgo: 5)),
            .localImage(image(minutesAgo: 10)),
            .remoteImage(remoteImage("img-1", minutesAgo: 20)),
        ]
    }
}

@Suite struct LibraryKindTests {
    let rows = LibraryMediaFixture.rows()

    @Test func kindPicksItsMedia() {
        #expect(LibraryFilter().apply(rows, kind: .all).count == 4)
        #expect(LibraryFilter().apply(rows, kind: .video).allSatisfy { $0.isVideo })
        #expect(LibraryFilter().apply(rows, kind: .video).count == 2)
        #expect(LibraryFilter().apply(rows, kind: .image).allSatisfy { !$0.isVideo })
        #expect(LibraryFilter().apply(rows, kind: .image).count == 2)
    }

    @Test func videoFiltersNeverTouchImages() {
        let filtered = LibraryFilter(mode: .motionTransfer).apply(rows, kind: .all)
        #expect(filtered.count == 3)
        #expect(filtered.filter { !$0.isVideo }.count == 2)
        #expect(LibraryFilter(finish: .drafts).apply(rows, kind: .all).filter { !$0.isVideo }.count == 2)
        #expect(LibraryFilter(resolution: .p1080).apply(rows, kind: .all).filter { !$0.isVideo }.count == 2)
    }

    @Test func imageFiltersNeverTouchVideos() {
        let filtered = LibraryFilter(imageModel: "Higgsfield Soul 2.0").apply(rows, kind: .all)
        #expect(filtered.filter { $0.isVideo }.count == 2)
        #expect(filtered.filter { !$0.isVideo }.count == 1)
        #expect(
            LibraryFilter(imageAspectRatio: "9:16").apply(rows, kind: .all).filter { $0.isVideo }.count == 2)
    }

    @Test func imageSearchMatchesEveryWordAgainstPromptAndModel() {
        #expect(LibraryFilter(query: "knight armor").apply(rows, kind: .image).count == 1)
        #expect(LibraryFilter(query: "soul knight").apply(rows, kind: .image).count == 1)
        #expect(LibraryFilter(query: "knight dance").apply(rows, kind: .image).isEmpty)
        #expect(LibraryFilter(query: "soul").apply(rows, kind: .image).count == 2)
        #expect(LibraryFilter(query: "camera").apply(rows, kind: .image).isEmpty)
    }

    @Test func starredCoversStarsAndLikes() {
        var starred = rows
        if case .video(var item) = starred[0] {
            item.isStarred = true
            starred[0] = .video(item)
        }
        if case .localImage(var image) = starred[2] {
            image.isStarred = true
            starred[2] = .localImage(image)
        }
        let only = LibraryFilter(isStarredOnly: true).apply(starred, kind: .all)
        #expect(only.count == 2)
        // The remote image's like is its star.
        var liked = starred
        if case .remoteImage(var remote) = liked[3] {
            remote.isLiked = true
            liked[3] = .remoteImage(remote)
        }
        #expect(LibraryFilter(isStarredOnly: true).apply(liked, kind: .all).count == 3)
    }

    @Test func querySurvivesAKindChange() {
        // The app keeps the query when the kind or origin changes; the filter itself doesn't clear it.
        let filter = LibraryFilter(query: "knight")
        #expect(filter.apply(rows, kind: .image).count == 1)
        #expect(filter.apply(rows, kind: .video).isEmpty)
        #expect(filter.apply(rows, kind: .all).count == 1)
    }
}

@Suite struct LibraryFilterVisibilityTests {
    @Test func eachKindShowsOnlyTheFiltersThatCanChangeItsGrid() {
        #expect(
            LibraryFilter.Field.visible(for: .video)
                == [.mode, .model, .resolution, .finish, .starred, .rejected, .sort])
        #expect(
            LibraryFilter.Field.visible(for: .image) == [.imageModel, .imageAspectRatio, .starred, .rejected, .sort])
        #expect(
            LibraryFilter.Field.visible(for: .all)
                == [
                    .mode, .model, .resolution, .finish, .imageModel, .imageAspectRatio, .starred, .rejected, .sort,
                ])
    }
}

@Suite struct LibraryKindCountsTests {
    let rows = LibraryMediaFixture.rows()

    @Test func countsMatchTheFilteredGrid() {
        for kind in LibraryKind.allCases {
            let filter = LibraryFilter(query: "soul")
            #expect(filter.apply(rows, kind: kind).count == filter.counts(rows).count(for: kind))
        }
        let counts = LibraryFilter(mode: .restyle).counts(rows)
        #expect(counts == LibraryKindCounts(videos: 1, images: 2))
        #expect(counts.all == 3)
    }

    @Test func countsIgnoreOnlyTheKind() {
        // A video-only filter still leaves the images counted, and the other way round.
        #expect(LibraryFilter(mode: .motionTransfer).counts(rows).images == 2)
        #expect(LibraryFilter(imageModel: "no such model").counts(rows) == LibraryKindCounts(videos: 2, images: 0))
    }
}

@Suite struct LibraryInterleavingTests {
    let rows = LibraryMediaFixture.rows()

    @Test func allInterleavesByDateNewestFirst() {
        let all = LibraryFilter().apply(rows, kind: .all)
        #expect(all.map(\.createdAt) == all.map(\.createdAt).sorted(by: >))
        // dance video (5 min), knight image (10 min), remote image (20 min), restyle video (36 min).
        #expect(all.map(\.isVideo) == [true, false, false, true])
    }

    @Test func oldestReversesTheInterleaving() {
        let oldest = LibraryFilter(sort: .oldest).apply(rows, kind: .all)
        #expect(oldest.map(\.createdAt) == oldest.map(\.createdAt).sorted(by: <))
        #expect(oldest.first?.isVideo == true && oldest.last?.isVideo == true)
    }

    @Test func highestPriceSortsVideosFirstAndImagesLast() {
        let priced = LibraryFilter(sort: .highestPrice).apply(rows, kind: .all)
        #expect(priced.prefix(2).allSatisfy { $0.isVideo })
        #expect(priced.suffix(2).allSatisfy { !$0.isVideo })
    }
}

@Suite struct HistoryImageFrameTests {
    @Test func aspectRatioReducesTheSize() {
        #expect(LibraryMediaFixture.remoteImage("a").aspectRatio == "1:1")
        var wide = LibraryMediaFixture.remoteImage("b")
        wide.pixelSize = PixelSize(width: 1920, height: 1080)
        #expect(wide.aspectRatio == "16:9")
        var unknown = LibraryMediaFixture.remoteImage("c")
        unknown.pixelSize = nil
        #expect(unknown.aspectRatio == nil)
    }
}

@Suite struct AccountHistoryImageTests {
    @Test func imagesMergeAcrossPagesAndSurviveARefresh() throws {
        var history = AccountHistory(owner: "me")
        var request = try history.begin(refresh: true)
        let first = HistoryPage(
            items: [HistoryFixture.item("gen-1")],
            images: [LibraryMediaFixture.remoteImage("img-1"), LibraryMediaFixture.remoteImage("img-2")],
            nextCursor: HistoryCursor("next"))
        let added = history.receive(first, for: request)
        #expect(!added)
        #expect(history.images.map(\.id) == ["img-1", "img-2"])

        request = try history.begin(refresh: false)
        let second = HistoryPage(
            items: [], images: [LibraryMediaFixture.remoteImage("img-2"), LibraryMediaFixture.remoteImage("img-3")],
            nextCursor: nil)
        let continues = history.receive(second, for: request)
        #expect(!continues)
        #expect(history.images.map(\.id) == ["img-1", "img-2", "img-3"])
        // A repeated ID keeps its first library ID.
        #expect(history.images[1].jobID == first.images[1].jobID)

        request = try history.begin(refresh: true)
        history.receive(HistoryPage(items: [], images: [], nextCursor: nil), for: request)
        #expect(history.images.isEmpty)
    }

    @Test func aLikeSetsTheImageStar() throws {
        var history = AccountHistory(owner: "me")
        let request = try history.begin(refresh: true)
        history.receive(
            HistoryPage(items: [], images: [LibraryMediaFixture.remoteImage("img-1")], nextCursor: nil),
            for: request)
        history.setLiked("img-1", true)
        #expect(history.images.first?.isLiked == true)
    }
}

@Suite struct LibraryKindSelectionTests {
    private struct Rows {
        let video: LibraryItemModel
        let image: LibraryMediaItem
        let grid: [LibraryGridRow]
    }

    private func rows() -> Rows {
        let video = LibraryFixture.item(minutesAgo: 5)
        let image = LibraryMediaItem.localImage(LibraryMediaFixture.image(minutesAgo: 10))
        return Rows(video: video, image: image, grid: [.entry(.item(video)), .image(image)])
    }

    @Test func imagesKindSelectsOnlyImages() {
        let selected = rows()
        #expect(LibraryKindSelection.entries(for: .image, in: selected.grid).isEmpty)
        #expect(LibraryKindSelection.imageIDs(for: .image, in: selected.grid) == [selected.image.id])
        #expect(LibraryKindSelection.videos(for: .image, in: [selected.video]).isEmpty)
    }

    @Test func videosKindSelectsOnlyVideos() {
        let selected = rows()
        #expect(LibraryKindSelection.entries(for: .video, in: selected.grid).map(\.id) == [selected.video.id])
        #expect(LibraryKindSelection.imageIDs(for: .video, in: selected.grid).isEmpty)
        #expect(LibraryKindSelection.videos(for: .video, in: [selected.video]) == [selected.video])
    }

    @Test func allKindSelectsBoth() {
        let selected = rows()
        #expect(LibraryKindSelection.entries(for: .all, in: selected.grid).map(\.id) == [selected.video.id])
        #expect(LibraryKindSelection.imageIDs(for: .all, in: selected.grid) == [selected.image.id])
        #expect(LibraryKindSelection.videos(for: .all, in: [selected.video]) == [selected.video])
    }

    @Test func selectAllInImagesNeverTouchesVideos() {
        // ⌘A in Images used to fill the video selection, so ⌘⌫ offered to delete hidden videos.
        let selected = rows()
        var selection = LibrarySelection()
        selection.selectAll(LibraryKindSelection.entries(for: .image, in: selected.grid))
        #expect(selection.items(in: [selected.video]).isEmpty)
        #expect(LibraryBulkActions(selection.items(in: [selected.video])).deletable.isEmpty)
    }
}

@Suite struct AccountHistoryPagingTests {
    @Test func progressAdvancesOnImagesOnlyPages() throws {
        var history = AccountHistory(owner: "me")
        let start = history.pagingProgress

        var request = try history.begin(refresh: true)
        history.receive(
            HistoryPage(
                items: [], images: [LibraryMediaFixture.remoteImage("img-1")],
                nextCursor: HistoryCursor("c1")),
            for: request)
        let afterFirst = history.pagingProgress
        // Only images arrived, yet the footer's task must refire for the next page.
        #expect(afterFirst != start)
        #expect(afterFirst.videos == 0 && afterFirst.images == 1)
        #expect(history.hasMore)

        request = try history.begin(refresh: false)
        history.receive(
            HistoryPage(
                items: [], images: [LibraryMediaFixture.remoteImage("img-2")],
                nextCursor: HistoryCursor("c2")),
            for: request)
        #expect(history.pagingProgress != afterFirst)
        #expect(history.pagingProgress.images == 2)
        #expect(history.hasMore)
    }

    @Test func progressStallsOnlyPastTheLastPage() throws {
        var history = AccountHistory(owner: "me")
        var request = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"]), for: request)
        let loaded = history.pagingProgress
        #expect(!history.hasMore)

        request = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"]), for: request)
        // A refresh with the same content and no cursor reads as no progress.
        #expect(history.pagingProgress == loaded)
    }
}

@Suite struct LibraryArrangeTests {
    @Test func entriesAndImagesInterleaveByDate() {
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var first = LibraryFixture.item(minutesAgo: 40)
        first.job.batchID = batchID
        var second = LibraryFixture.item(minutesAgo: 2)
        second.job.batchID = batchID
        let single = LibraryFixture.item(mode: .motionTransfer, source: "dance.mp4", minutesAgo: 30)
        let entries = LibraryEntry.group([second, single, first])
        #expect(entries.count == 2)
        let image = LibraryMediaItem.localImage(LibraryMediaFixture.image(minutesAgo: 10))
        let rows = LibraryMediaGrid.arrange(entries: entries, images: [image], sort: .newest)
        // Batch (newest result 2 min), image (10 min), single video (30 min).
        #expect(rows.map(\.id) == [entries[0].id, image.id, entries[1].id])
        let oldest = LibraryMediaGrid.arrange(entries: entries, images: [image], sort: .oldest)
        #expect(oldest.map(\.id) == [entries[1].id, image.id, entries[0].id])
    }

    @Test func highestPriceKeepsEntriesFirst() {
        let entry = LibraryEntry.item(LibraryFixture.item())
        let image = LibraryMediaItem.localImage(LibraryMediaFixture.image())
        let rows = LibraryMediaGrid.arrange(entries: [entry], images: [image], sort: .highestPrice)
        #expect(rows.map(\.id) == [entry.id, image.id])
    }
}

@Suite struct ImageCompareTests {
    private func image(_ id: UUID, _ name: String) -> CompareImage {
        CompareImage(id: id, fileURL: URL(fileURLWithPath: "/tmp/\(name).png"), prompt: name)
    }

    @Test func needsTwoDifferentImages() {
        let first = image(UUID(), "knight")
        #expect(ImageComparePair(first, first) == nil)
        #expect(ImageComparePair(first, image(UUID(), "dance")) != nil)
    }

    @Test func swappingTwiceRestoresTheSides() throws {
        let left = image(UUID(), "knight")
        let right = image(UUID(), "dance")
        var pair = try #require(ImageComparePair(left, right))
        pair.swap()
        #expect(pair.left.id == right.id && pair.right.id == left.id)
        pair.swap()
        #expect(pair.left.id == left.id)
    }

    @Test func oneStateDrivesBothPanes() {
        var state = ImageCompareState()
        #expect(state.zoom == 1 && state.offsetX == 0 && state.offsetY == 0 && state.fitsPane)
        state.setZoom(2.5)
        state.pan(byX: 30, y: -12)
        // Both panes read this same state, so whatever it holds, they share.
        let shared = state
        #expect(shared.zoom == 2.5 && shared.offsetX == 30 && shared.offsetY == -12)
        state.showActualSize()
        #expect(state.zoom == 1 && state.offsetX == 0 && state.offsetY == 0 && !state.fitsPane)
        state.showFit()
        #expect(state == ImageCompareState())
    }

    @Test func actualSizeIsOneToOneWhateverThePaneHolds() {
        // A 4000px image in a 400pt pane fits at 0.1; Actual Size must show 4000, not 400.
        let fit = ImageCompareState.fitScale(imageWidth: 4000, imageHeight: 3000, paneWidth: 400, paneHeight: 400)
        #expect(abs(fit - 0.1) < 0.0001)
        var actual = ImageCompareState()
        actual.showActualSize()
        #expect(actual.displayScale(fitScale: fit) == 1)
        #expect(4000 * actual.displayScale(fitScale: fit) == 4000)
        #expect(4000 * ImageCompareState().displayScale(fitScale: fit) == 400)
    }

    @Test func fitNeverMagnifiesPastActualSize() {
        #expect(ImageCompareState.fitScale(imageWidth: 100, imageHeight: 100, paneWidth: 400, paneHeight: 400) == 1)
        #expect(ImageCompareState.fitScale(imageWidth: 0, imageHeight: 100, paneWidth: 400, paneHeight: 400) == 1)
    }

    @Test func zoomStaysWithinItsRange() {
        var state = ImageCompareState()
        state.setZoom(100)
        #expect(state.zoom == ImageCompareState.maxZoom)
        state.setZoom(0)
        #expect(state.zoom == ImageCompareState.minZoom)
    }
}
