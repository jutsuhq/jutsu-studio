import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Create's Variants (`JobSpec.variants`): several results of one request from one submit, on an account.
@Suite struct CreateVariantsTests {
    static func account(
        maxVariants: Int = 4, unlimited: [VideoModel: Set<Mode>] = [:], optedIn: Bool = false
    )
        -> CreateContext
    {
        var context = CreateContext(connection: .account(AccountInfo(credits: 1_000)), unlimitedOptIn: optedIn)
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases), resolutions: Set(Resolution.allCases),
            costUnit: .credits, maxConcurrency: nil, unlimited: unlimited, maxVariants: maxVariants)
        return context
    }

    @Test func theJobsAskForThePickedVariants() {
        var form = CreateFixture.ready()
        form.variants = 3
        let context = Self.account()
        #expect(form.variantsUnavailableReason(in: context) == nil)
        #expect(form.makeSpecs(isDraft: false, in: context).map(\.variants) == [3])
        #expect(form.makeSpecs(isDraft: true, in: context).map(\.variants) == [3])
        // Without a context the jobs make one.
        #expect(form.makeSpecs(isDraft: false).map(\.variants) == [1])
    }

    @Test func thePickStaysInsideOneToFour() {
        var form = CreateForm()
        form.variants = 9
        #expect(form.variants == 4)
        form.variants = 0
        #expect(form.variants == 1)
    }

    /// The account caps an unlimited request to one generation, so the form asks for one and says why.
    @Test func theUnlimitedAllowanceHoldsItAtOne() {
        var form = CreateFixture.ready()
        form.variants = 3
        let context = Self.account(unlimited: [.genjutsu: [.motionTransfer]], optedIn: true)
        #expect(form.variantsUnavailableReason(in: context) == "Unlimited generations make one video at a time")
        #expect(form.variants(in: context) == 1)
        #expect(form.makeSpecs(isDraft: false, in: context).map(\.variants) == [1])
        // Turning the allowance off again keeps the pick.
        #expect(form.variants(in: Self.account()) == 3)
    }

    @Test func anAPIKeyHidesItAndMakesOne() {
        var form = CreateFixture.ready()
        form.variants = 3
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil)
        #expect(!form.showsVariants(in: context))
        #expect(form.makeSpecs(isDraft: false, in: context).map(\.variants) == [1])
        #expect(form.showsVariants(in: Self.account()))
    }

    @Test func aStyleAndABatchMakeOne() {
        var form = CreateFixture.ready()
        form.variants = 2
        form.isBatch = true
        #expect(form.variants(in: Self.account()) == 1)
        #expect(form.variantsUnavailableReason(in: Self.account()) != nil)
        form.isBatch = false
        form.mode = .restyle
        #expect(form.variantsUnavailableReason(in: Self.account()) == "A style makes one video per run")
    }

    @Test func unknownCapabilitiesMakeOne() {
        var form = CreateFixture.ready()
        form.variants = 3
        let context = CreateContext(connection: .account(AccountInfo(credits: 1_000)))
        #expect(form.variants(in: context) == 1)
        #expect(!form.showsVariants(in: context))
    }

    /// The capabilities decide, not the kind of connection: an account without variants hides the stepper too.
    @Test func aConnectionWithoutVariantsHidesIt() {
        #expect(!CreateFixture.ready().showsVariants(in: Self.account(maxVariants: 1)))
        #expect(CreateFixture.ready().showsVariants(in: Self.account(maxVariants: 2)))
    }

    /// The estimate of a spec of several variants is for all of them; the cost line counts every variant.
    @Test func theCostLineCountsEveryVariant() throws {
        var form = CreateFixture.ready()
        form.variants = 3
        var context = Self.account()
        let spec = try #require(form.makeSpecs(isDraft: false, in: context).first)
        context.estimates[spec.priceKey] = .credits(90, isEstimate: true)

        let line = try #require(form.costLine(in: context))
        #expect(line.text == "45 s = 90 credits")
        #expect(line.detail.contains("3 jobs"))
        #expect(form.priceText(isDraft: false, in: context) == CostText.text(.credits(90, isEstimate: true)))
    }

    @Test func loadingAJobKeepsItsVariants() {
        var spec = CreateFixture.ready().makeSpecs(isDraft: false)[0]
        spec.variants = 2
        var form = CreateForm()
        form.load(spec, source: CreateFixture.video())
        #expect(form.variants == 2)
        spec.variants = 1
        form.load(spec, source: CreateFixture.video())
        #expect(form.variants == 1)
    }
}

@Suite struct VariantBatchTests {
    static func variant(_ batch: UUID, minutesAgo: Double) -> Job {
        var job = JobFixture.job(.done, createdMinutesAgo: minutesAgo)
        job.batchID = batch
        return job
    }

    @Test func theJobsOfOneSubmitAreCalledVariants() throws {
        let batch = UUID()
        let group = JobBatch(id: batch, jobs: [Self.variant(batch, minutesAgo: 2), Self.variant(batch, minutesAgo: 2)])
        #expect(group.title == "dance · Motion transfer batch · 2 variants")

        let items = group.jobs.map { LibraryItemModel(job: $0, presetName: nil) }
        let library = try #require(LibraryBatch(id: batch, in: items))
        #expect(library.cells(presetNames: [:]).map(\.label) == ["Variant 1", "Variant 2"])
        #expect(library.title.hasSuffix("· 2 variants"))
    }

    @Test func charactersAreNotVariants() {
        let batch = UUID()
        var second = Self.variant(batch, minutesAgo: 1)
        second.spec.references = [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/other.png"))]
        let group = JobBatch(id: batch, jobs: [Self.variant(batch, minutesAgo: 2), second])
        #expect(group.title.hasSuffix("· 2 characters"))
    }

    @Test func aJobMissingVariantsSaysSo() {
        var job = JobFixture.job(.processing, kind: .account)
        job.missingVariants = 2
        let row = JobRowModel(job, now: JobFixture.now)
        #expect(row.note?.text == "Higgsfield started fewer variants than asked for: 2 missing")

        var waiting = JobFixture.job(.uploading, kind: .account)
        waiting.spec.variants = 3
        #expect(JobRowModel(waiting, now: JobFixture.now).meta.contains("3 variants"))
    }
}
