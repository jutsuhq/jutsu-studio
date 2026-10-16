import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct KlingQualityTests {
    /// Every model offered, with the bundled list prices.
    static let apiKey: CreateContext = {
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases), resolutions: Set(Resolution.allCases),
            costUnit: .usd, maxConcurrency: nil)
        return context
    }()

    static func kling(_ resolution: Resolution = .p720) -> CreateForm {
        var form = CreateFixture.ready(resolution)
        form.model = .klingMotionControl
        return form
    }

    @Test func klingOffersStandardAndProInsteadOfResolutions() {
        var form = Self.kling(.p480)
        #expect(form.showsKlingQuality)
        #expect(KlingQuality.allCases.map(\.title) == ["Standard", "Pro"])
        #expect(form.klingQuality == .standard)
        #expect(form.makeSpecs(isDraft: false).map(\.resolution) == [.p720])

        form.klingQuality = .pro
        #expect(form.resolution == .p1080)
        #expect(form.makeSpecs(isDraft: false).map(\.endpointID) == ["kling-video/v3/motion-control/pro"])

        form.model = .genjutsu
        #expect(!form.showsKlingQuality)
        #expect(form.makeSpecs(isDraft: false).map(\.resolution) == [.p1080])
    }

    @Test func klingOffersNoDraft() {
        CostText.$locale.withValue(.enUS) {
            var form = Self.kling()
            form.setSource(CreateFixture.video(duration: 20))
            form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
            #expect(!form.offersDraft)
            #expect(!form.showsDraftLength)
            #expect(form.makeSpecs(isDraft: true) == form.makeSpecs(isDraft: false))
            #expect(form.makeSpecs(isDraft: true).allSatisfy { !$0.isDraft })

            let state = SubmitBarState(form: form, in: Self.apiKey)
            #expect(state.generateBlocker == nil)
            #expect(state.draftBlocker == nil && state.draftPrice == nil)
            #expect(state.generatePrice == "$2.52")

            form.model = .genjutsu
            #expect(form.offersDraft)
            #expect(form.showsDraftLength)
        }
    }

    @Test func aKlingBatchRunsAsFinals() {
        var form = Self.kling()
        form.isBatch = true
        #expect(!form.runsAsDraft)
        let primary = form.primarySubmit(in: Self.apiKey)
        #expect(!primary.isDraft)
        #expect(primary.title == form.generateButtonTitle)
        #expect(form.makeSpecs(isDraft: false).allSatisfy { !$0.isDraft })

        form.model = .genjutsu
        #expect(form.runsAsDraft)
        #expect(form.primarySubmit(in: Self.apiKey).isDraft)
    }

    /// 14.2 s billed as 15 s: Standard at $0.126, Pro at $0.168 a second.
    @Test func costFollowsTheQuality() {
        CostText.$locale.withValue(.enUS) {
            var form = Self.kling(.p480)
            #expect(form.rateText(in: Self.apiKey) == "$0.126 / s")
            #expect(form.priceText(isDraft: false, in: Self.apiKey) == "$1.89")
            #expect(form.costLine(in: Self.apiKey)?.text == "15 s = $1.89")

            form.klingQuality = .pro
            #expect(form.rateText(in: Self.apiKey) == "$0.168 / s")
            #expect(form.priceText(isDraft: false, in: Self.apiKey) == "$2.52")
        }
    }

    @Test func notEnoughCreditsDoesntSuggestADraft() throws {
        let form = Self.kling()
        let spec = try #require(form.makeSpecs(isDraft: false).first)
        var context = CreateContext(
            connection: .account(AccountInfo(credits: 10)), estimates: [spec: .credits(25, isEstimate: true)])
        context.capabilities = Self.apiKey.capabilities
        #expect(form.blocker(isDraft: false, in: context) == "Not enough credits on your plan")
    }

    @Test func anOldKlingDraftDecodesAsStandardAndRendersAProFinal() throws {
        let json = #"""
            {"mode": "motionTransfer", "model": "klingMotionControl", "references": [], "prompt": "",
             "resolution": "480p", "isDraft": true}
            """#
        let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
        #expect(KlingQuality(spec.resolution) == .standard)
        #expect(spec.resolutionTitle == "Standard")
        #expect(spec.endpointID == "kling-video/v3/motion-control/std")

        var job = Job(spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: true), createdAt: Date())
        job.state = .done
        let item = LibraryItemModel(job: job)
        #expect(item.canRenderFinal)
        #expect(item.finalResolutions == [.p1080])
        let final = item.finalSpec(at: .p720)
        #expect(final.resolution == .p1080 && !final.isDraft)
        #expect(final.resolutionTitle == "Pro")
        #expect(item.templateSpec(finalResolution: .p720).resolution == .p480)

        #expect(LibraryFixture.item().finalResolutions == [.p720, .p1080])
        #expect(LibraryFixture.item().finalSpec(at: .p720).resolution == .p720)
    }

    @Test func listsNameTheKlingQuality() {
        let template = JobTemplate(
            name: "Dance", mode: .motionTransfer, model: .klingMotionControl, references: [], presetID: nil,
            prompt: "", resolution: .p1080, audio: .original)
        #expect(template.summary.hasSuffix("Kling 3.0 · Pro"))
        #expect(Resolution.p720.title(on: .genjutsu) == "720p")
    }
}
