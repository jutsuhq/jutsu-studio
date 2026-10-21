import Foundation
import JutsuCore
import Testing

@testable import Presentation

private let presetIDs = (0..<13).map { _ in UUID() }

private func images(_ range: Range<Int>) -> [LocalImage] {
    CreateFixture.references(range.map(CreateFixture.image))
}

/// Restyle on a 13 s clip, so every job bills 13 s.
private func restyleBatch(styles: Int) -> CreateForm {
    var form = CreateForm(mode: .restyle, resolution: .p720)
    form.setSource(CreateFixture.video(duration: 13))
    form.isBatch = true
    for id in presetIDs.prefix(styles) { form.toggleBatchPreset(id) }
    return form
}

@Suite struct BatchPlanningTests {
    @Test func restyleBatchQueuesTheRangeOncePerStyleAsDrafts() {
        let form = restyleBatch(styles: 3)
        let specs = form.makeSpecs(isDraft: true)
        #expect(specs.map(\.presetID) == presetIDs.prefix(3).map { $0 })
        #expect(specs.allSatisfy { $0.source?.range == 0...13 && $0.resolution == .p480 && $0.isDraft })
        #expect(form.draftButtonTitle == "Draft 480p × 3")
        #expect(form.generateButtonTitle == "Generate × 3")
        #expect(form.batchCountText == "3 / 12")
    }

    @Test func characterBatchQueuesOneJobPerSet() {
        var form = CreateFixture.ready()
        form.isBatch = true
        #expect(form.characterSets == [images(1..<2)])
        let message = form.addCharacterSet(images(2..<4))
        #expect(message == nil)
        let specs = form.makeSpecs(isDraft: false)
        #expect(specs.map(\.references) == [images(1..<2), images(2..<4)])
        #expect(specs.allSatisfy { $0.resolution == .p720 && !$0.isDraft })
        #expect(form.blocker(isDraft: true, in: CreateFixture.apiKey) == nil)
    }

    @Test func turningTheBatchOnStartsFromTheChosenStyle() {
        var form = CreateForm(mode: .restyle)
        form.presetID = presetIDs[0]
        form.isBatch = true
        #expect(form.batchPresetIDs == [presetIDs[0]])
        form.toggleBatchPreset(presetIDs[0])
        #expect(form.batchPresetIDs.isEmpty)
    }

    @Test func aCharacterSetKeepsEightDistinctImages() {
        var form = CreateFixture.ready()
        form.isBatch = true
        let message = form.addCharacterSet(images(10..<20) + images(10..<11))
        #expect(form.characterSets.last == images(10..<18))
        #expect(message?.title == "2 images weren't added")
        let none = form.addCharacterSet([])
        #expect(none == nil)
        form.removeCharacterSet(at: 0)
        #expect(form.characterSets == [images(10..<18)])
    }

    @Test func aSavedCharacterSetIsKnownForItsAccountUntilItIsRemoved() throws {
        var form = CreateFixture.ready()
        form.isBatch = true
        form.addCharacterSet(images(2..<4))
        let saved = SavedElement(id: "el-1", owner: "user_1")

        form.setSavedElement(saved, forCharacterSet: images(2..<4))

        #expect(form.savedElement(ofCharacterSet: 1, owner: "user_1") == saved)
        #expect(form.savedElement(ofCharacterSet: 1, owner: "user_2") == nil)
        #expect(form.savedElement(ofCharacterSet: 0, owner: "user_1") == nil)
        // Kept in the saved draft.
        let decoded = try JSONDecoder().decode(CreateForm.self, from: try JSONEncoder().encode(form))
        #expect(decoded.savedElement(ofCharacterSet: 1, owner: "user_1") == saved)
        form.removeCharacterSet(at: 1)
        form.addCharacterSet(images(2..<4))
        #expect(form.savedElement(ofCharacterSet: 1, owner: "user_1") == nil)
    }

    @Test func aSavedSetStaysSavedWhenItsFilesReopenElsewhere() {
        var form = CreateFixture.ready()
        form.isBatch = true
        form.addCharacterSet(images(2..<4))
        form.addCharacterSet(images(5..<7))
        form.setSavedElement(SavedElement(id: "el-1", owner: nil), forCharacterSet: images(2..<4))
        form.setSavedElement(SavedElement(id: "el-2", owner: nil), forCharacterSet: images(5..<7))

        let reopened = form.reopeningFiles { image in
            if image.fileURL == images(6..<7)[0].fileURL { return nil }
            return LocalImage(fileURL: image.fileURL.appendingPathExtension("moved"))
        }

        #expect(reopened.savedElement(ofCharacterSet: 1, owner: nil)?.id == "el-1")
        // A set that lost a file isn't the one that was published.
        #expect(reopened.savedElement(ofCharacterSet: 2, owner: nil) == nil)
    }

    @Test func loadingAJobLeavesTheBatch() {
        var form = restyleBatch(styles: 2)
        let spec = form.makeSpecs(isDraft: true)[1]
        form.load(spec, source: CreateFixture.video(duration: 13))
        #expect(!form.isBatch)
        #expect(form.makeSpecs(isDraft: false).map(\.presetID) == [presetIDs[1]])
    }

    @Test func batchBlockers() {
        let context = CreateFixture.apiKey
        #expect(restyleBatch(styles: 1).blocker(isDraft: true, in: context) == "Pick at least 2 styles")
        var characters = CreateFixture.ready()
        characters.isBatch = true
        #expect(characters.blocker(isDraft: true, in: context) == "Add at least 2 characters")

        var ranges = restyleBatch(styles: 2)
        ranges.setEnd(5)
        ranges.addRange()
        #expect(ranges.blocker(isDraft: true, in: context) == "A batch uses one range, remove the others")

        var swap = CreateForm(mode: .objectSwap)
        swap.setSource(CreateFixture.video(width: 480, height: 480))
        swap.isBatch = true
        swap.addCharacterSet(images(1..<2))
        swap.addCharacterSet(images(2..<3))
        #expect(
            swap.blocker(isDraft: true, in: context) == "Character 1: Object swap needs 640×640 px, allow the upscale")
    }
}

@Suite struct BatchCapTests {
    @Test func twelveStylesIsTheLimit() {
        var form = restyleBatch(styles: 12)
        #expect(form.batchCapNotice == "A batch takes up to 12 styles. Remove one to add another.")
        let refused = form.toggleBatchPreset(presetIDs[12])
        #expect(!refused)
        #expect(form.batchCount == 12)
        let removed = form.toggleBatchPreset(presetIDs[0])
        #expect(removed)
        #expect(form.batchCapNotice == nil)
        let added = form.toggleBatchPreset(presetIDs[12])
        #expect(added)
        #expect(form.batchPresetIDs.last == presetIDs[12])
    }

    @Test func twelveCharactersIsTheLimit() {
        var form = CreateFixture.ready()
        form.isBatch = true
        for index in 1..<12 { form.addCharacterSet(images(index * 10..<index * 10 + 1)) }
        #expect(form.batchCount == 12)
        let message = form.addCharacterSet(images(200..<201))
        #expect(message?.title == "A batch takes up to 12 characters")
        #expect(form.batchCount == 12)
        #expect(!form.canAddBatchVariant)
    }
}

@Suite struct BatchPriceTests {
    @Test func totalAddsUnroundedJobPricesThenRounds() {
        CostText.$locale.withValue(.enUS) {
            // 13 s × $0.318 = $4.134 a job; seven of them are $28.938, not 7 × $4.13.
            let form = restyleBatch(styles: 7)
            let context = CreateFixture.apiKey
            #expect(form.priceText(isDraft: true, in: context) == "$28.94")
            let line = form.costLine(in: context)
            #expect(line?.text == "91 s × $0.318 = $28.94")
            #expect(line?.detail == "List price · 7 jobs · failed runs are free")
            #expect(form.priceText(isDraft: false, in: context) == "$61.97")
        }
    }

    @Test func creditsTotalNeedsEveryEstimate() {
        let form = restyleBatch(styles: 2)
        let specs = form.makeSpecs(isDraft: true)
        var context = CreateContext(
            connection: .apiKey(keyID: "kid"), estimates: [specs[0]: .credits(12, isEstimate: true)])
        #expect(context.cost(for: specs) == nil)
        context.estimates[specs[1]] = .credits(14, isEstimate: true)
        #expect(context.cost(for: specs) == .credits(26, isEstimate: true))
    }

    @Test func mixedUnitsHaveNoTotal() {
        #expect(Cost.total([]) == nil)
        #expect(Cost.total([.usd(1, isEstimate: false), .credits(3, isEstimate: false)]) == nil)
        #expect(Cost.total([.usd(1, isEstimate: false), .usd(2, isEstimate: true)]) == .usd(3, isEstimate: true))
    }

    @Test func overTheCapAsksOnceForTheWholeBatch() {
        CostText.$locale.withValue(.enUS) {
            let form = restyleBatch(styles: 7)
            var context = CreateFixture.apiKey
            context.cap = .usd(20)
            guard case .confirm(let specs, let confirmation) = form.submitDecision(isDraft: true, in: context) else {
                Issue.record("expected a confirmation")
                return
            }
            #expect(specs.count == 7)
            #expect(
                confirmation.message == "These 7 jobs add $28.94, bringing today to $28.94 against your $20.00 cap.")
            context.cap = .usd(30)
            #expect(form.submitDecision(isDraft: true, in: context) == .start(form.makeSpecs(isDraft: true)))
            #expect(form.costLine(in: context)?.isWarning == false)
        }
    }
}

@Suite struct SubmitBarStateTests {
    private static func expectMatches(_ form: CreateForm, _ context: CreateContext) {
        let state = SubmitBarState(form: form, in: context)
        #expect(state.draftBlocker == form.blocker(isDraft: true, in: context))
        #expect(state.generateBlocker == form.blocker(isDraft: false, in: context))
        #expect(state.costLine == form.costLine(in: context))
        #expect(state.draftPrice == form.priceText(isDraft: true, in: context))
        #expect(state.generatePrice == form.priceText(isDraft: false, in: context))
    }

    @Test func matchesTheFormForASingleJobABatchAndBlockers() {
        var overCap = CreateFixture.apiKey
        overCap.cap = .usd(20)
        for context in [CreateFixture.apiKey, overCap, CreateContext(connection: ConnectionState.none)] {
            Self.expectMatches(CreateFixture.ready(), context)
            Self.expectMatches(restyleBatch(styles: 7), context)
            Self.expectMatches(restyleBatch(styles: 1), context)
            Self.expectMatches(CreateForm(mode: .motionTransfer), context)
        }
    }

    @Test func matchesTheFormOnCredits() {
        let form = CreateFixture.ready()
        let draft = form.makeSpecs(isDraft: true)
        let generate = form.makeSpecs(isDraft: false)
        var context = CreateContext(connection: .account(AccountInfo(credits: 30)))
        Self.expectMatches(form, context)
        context.lastTotals = [true: .credits(8, isEstimate: true), false: .credits(35, isEstimate: true)]
        Self.expectMatches(form, context)
        context.estimates[draft[0]] = .credits(10, isEstimate: true)
        context.estimates[generate[0]] = .credits(40, isEstimate: true)
        Self.expectMatches(form, context)
        #expect(SubmitBarState(form: form, in: context).generateBlocker != nil)
    }
}

@Suite struct BatchEnqueueTests {
    static let specs = restyleBatch(styles: 3).makeSpecs(isDraft: true)

    @Test func aBatchThatFailsPartwaySaysHowManyWereQueued() async {
        var queued: [JobSpec] = []
        let message = await BatchEnqueue.run(Self.specs, kind: .apiKey) { spec in
            guard queued.count < 2 else { throw ProviderError.network }
            queued.append(spec)
        }
        #expect(queued == Array(Self.specs.prefix(2)))
        #expect(message?.title == "2 of 3 jobs queued")
        #expect(message?.message == "Can't reach Higgsfield. Check your internet connection and try again.")
    }

    @Test func theFailureKeepsItsActionAndASilentOneStillCounts() {
        let funds = BatchEnqueue.message(for: ProviderError.insufficientFunds, queued: 1, of: 4, kind: .apiKey)
        #expect(funds?.title == "1 of 4 jobs queued")
        #expect(funds?.action == .openConsole)
        let cancelled = BatchEnqueue.message(for: CancellationError(), queued: 2, of: 3, kind: nil)
        #expect(cancelled == UserMessage(title: "2 of 3 jobs queued", message: "The rest weren't queued."))
    }

    @Test func aFirstFailureIsTheErrorsOwnAlertAndSuccessIsSilent() async {
        let first = await BatchEnqueue.run(Self.specs, kind: .apiKey) { _ in throw ProviderError.network }
        #expect(first == UserMessage(ProviderError.network, kind: .apiKey))
        let all = await BatchEnqueue.run(Self.specs, kind: .apiKey) { _ in }
        #expect(all == nil)
    }
}

@Suite struct BatchGallerySelectionTests {
    @Test func unknownSelectedStylesStayVisibleInOrder() {
        let known = StylePreset(id: presetIDs[0], name: "Noir", previewURL: URL(fileURLWithPath: "/p.png"))
        let sections = PresetShelf.sections(
            catalog: [known], favorites: [], recents: [], selections: [presetIDs[2], presetIDs[0], presetIDs[1]],
            query: "")
        #expect(sections.map(\.kind) == [.selected, .all])
        #expect(sections.first?.items.map(\.id) == [presetIDs[2], presetIDs[1]])
    }
}

private func batchJob(
    _ state: JobState, batch: UUID?, minutesAgo: Double, finishedMinutesAgo: Double? = nil, progress: Double = 0
) -> Job {
    var job = JobFixture.job(
        state, mode: .restyle, createdMinutesAgo: minutesAgo, finishedMinutesAgo: finishedMinutesAgo,
        progress: progress)
    job.batchID = batch
    return job
}

@Suite struct QueueGroupingTests {
    @Test func batchJobsGatherAtTheFirstOne() {
        let batch = UUID()
        let first = batchJob(.processing, batch: batch, minutesAgo: 5)
        let single = batchJob(.queued, batch: nil, minutesAgo: 4)
        let second = batchJob(.uploading, batch: batch, minutesAgo: 3)
        let alone = batchJob(.queued, batch: UUID(), minutesAgo: 2)
        let entries = QueueEntry.group([first, single, second, alone])
        #expect(entries.map(\.id) == [batch, single.id, alone.id])
        guard case .batch(let group) = entries.first else {
            Issue.record("expected a batch")
            return
        }
        #expect(group.jobs.map(\.id) == [first.id, second.id])
        #expect(group.title == "dance · Restyle batch · 2 styles")
    }

    @Test func combinedProgressCountsFinishedJobsWhole() {
        CostText.$locale.withValue(.enUS) {
            let batch = UUID()
            let group = JobBatch(
                id: batch,
                jobs: [
                    batchJob(.done, batch: batch, minutesAgo: 5, finishedMinutesAgo: 1),
                    batchJob(.uploading, batch: batch, minutesAgo: 4, progress: 0.5),
                    batchJob(.failed(reason: .message("x")), batch: batch, minutesAgo: 3, finishedMinutesAgo: 1),
                    batchJob(.queued, batch: batch, minutesAgo: 2),
                ])
            // done 1, upload step 1 of 4 at half (0.375), failed 1, generate step 2 of 4 (0.5).
            let expected = 2.875 / 4
            #expect(group.progress == expected)
            #expect(group.progressText == "1 of 4 done · 1 stopped")
            #expect(group.isActive)
            // The failed job wasn't charged: three of $8.168.
            #expect(group.totalCostText == "$24.50")
        }
    }

    @MainActor
    @Test func aRunningBatchStaysInActiveWithItsFinishedJobs() {
        let running = UUID()
        let finished = UUID()
        let live = LiveJobs([
            batchJob(.done, batch: running, minutesAgo: 9, finishedMinutesAgo: 1),
            batchJob(.processing, batch: running, minutesAgo: 8),
            batchJob(.done, batch: finished, minutesAgo: 7, finishedMinutesAgo: 3),
            batchJob(.done, batch: finished, minutesAgo: 6, finishedMinutesAgo: 2),
            batchJob(.done, batch: nil, minutesAgo: 5, finishedMinutesAgo: 4),
        ])
        #expect(live.activeEntries.map(\.id) == [running])
        #expect(live.activeCount == 1)
        let recent = live.recentFinishedEntries(limit: 8)
        #expect(recent.count == 2)
        #expect(recent.first?.id == finished)
        #expect(live.recentFinishedEntries(limit: 1).map(\.id) == [finished])
    }
}

@Suite struct LibraryBatchTests {
    /// Queued and finished `minutesAgo`, so an older member comes first in its batch.
    private func member(_ batch: UUID?, presetName: String?, minutesAgo: Double) -> LibraryItemModel {
        let base = LibraryFixture.item(presetName: presetName, minutesAgo: minutesAgo)
        var job = Job(
            spec: base.spec, providerKind: .apiKey, batchID: batch, cost: base.job.cost,
            createdAt: LibraryFixture.now.addingTimeInterval(-minutesAgo * 60 - 60))
        job.state = .done
        job.finishedAt = base.job.finishedAt
        return LibraryItemModel(job: job, presetName: presetName)
    }

    @Test func aBatchIsOneCardAtItsNewestResult() {
        let batch = UUID()
        let newest = member(batch, presetName: "Noir", minutesAgo: 1)
        let other = member(nil, presetName: nil, minutesAgo: 2)
        let oldest = member(batch, presetName: "Clay", minutesAgo: 3)
        let entries = LibraryEntry.group([newest, other, oldest])
        #expect(entries.map(\.id) == [batch, other.id])
        #expect(LibraryEntry.group([newest, other]).map(\.id) == [newest.id, other.id])
    }

    @Test func comparisonCellsAreLabeledByStyleOrCharacter() throws {
        try CostText.$locale.withValue(.enUS) {
            let batch = UUID()
            let named = member(batch, presetName: "Noir", minutesAgo: 2)
            let unnamed = member(batch, presetName: "Clay", minutesAgo: 1)
            let group = try #require(LibraryBatch(id: batch, in: [named, unnamed]))
            let names = [try #require(named.spec.presetID): "Film Noir"]
            #expect(group.cells(presetNames: names).map(\.label) == ["Film Noir", "Style 2"])
            #expect(group.title == "rooftop · 2 styles")
            #expect(group.subtitle(now: LibraryFixture.now) == "Draft 480p · $3.82 · 1 min ago")
            let label = group.accessibilityLabel(now: LibraryFixture.now)
            #expect(label == "Batch: rooftop · 2 styles, Draft 480p · $3.82 · 1 min ago")

            var swap = group
            swap.items = swap.items.map { item in
                var item = item
                item.job.spec.mode = .motionTransfer
                return item
            }
            #expect(swap.cells(presetNames: names).map(\.label) == ["Character 1", "Character 2"])
            #expect(LibraryBatch(id: batch, in: [named]) == nil)
        }
    }

    @Test func eachCellPlaysItsResultUnderItsLabel() throws {
        let batch = UUID()
        var first = member(batch, presetName: "Noir", minutesAgo: 2)
        first.job.outputFile = URL(fileURLWithPath: "/home/me/Movies/Jutsu Studio/noir.mp4")
        var second = member(batch, presetName: "Clay", minutesAgo: 1)
        second.job.outputFile = nil
        let group = try #require(LibraryBatch(id: batch, in: [first, second]))
        let cells = group.cells(presetNames: [:])

        let track = try #require(cells[0].track)
        #expect(track.id == CompareTrack.ID(itemID: first.id, side: .result))
        #expect(track.clip.url == first.outputFile)
        #expect(track.labels == ["Style 1"])
        #expect(cells[1].track == nil)
    }
}
