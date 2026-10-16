import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateFormEditExtendTests {
    /// Seedance with a 14.2 s source and a prompt.
    private func seedance(_ mode: Mode = .motionTransfer) -> CreateForm {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.model = .seedance25
        form.setSource(CreateFixture.video())
        form.prompt = "make it night"
        form.mode = mode
        return form
    }

    @Test func editAndExtendAreSeedancesTasksInTheMotionTab() throws {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        let tabs: [Mode] = [.motionTransfer, .restyle, .objectSwap]
        #expect(form.modeChoices == tabs)
        #expect(form.taskChoices(in: CreateFixture.apiKey) == [.motionTransfer])
        form.model = .seedance25
        #expect(form.taskChoices(in: CreateFixture.apiKey) == [.motionTransfer, .edit, .extend])

        form.pickTask(.edit)
        #expect(form.modeChoices == tabs)
        #expect(form.tab == .motionTransfer)
        #expect(form.modelOptions(in: CreateFixture.apiKey).contains(.genjutsu))
        form.setSource(nil)
        #expect(!form.isWithoutSource)
        #expect(form.makeSpecs(isDraft: false).isEmpty)

        // A model without Edit takes the form back to motion transfer; one that only edits takes it to Edit.
        form.model = .genjutsu
        #expect(form.mode == .motionTransfer)
        form.model = try #require(VideoModel(rawValue: "klingO3VideoEdit"))
        #expect(form.mode == .edit)

        form.tab = .restyle
        #expect(form.taskChoices(in: CreateFixture.apiKey).isEmpty)
        form.tab = .motionTransfer
        #expect(form.mode == .edit)
    }

    @Test func editRunsOnSeedanceAndNeedsAPrompt() {
        var form = seedance(.edit)
        #expect(form.selectedModel == .seedance25)
        #expect(form.promptTitle == "Prompt")
        #expect(!form.showsAddedLength)
        #expect(!form.offersBatch)

        let spec = try? #require(form.makeSpecs(isDraft: false).first)
        #expect(spec?.mode == .edit)
        #expect(spec?.model == .seedance25)
        #expect(spec?.length == nil)
        #expect(spec?.endpointID == "bytedance/seedance-2.5/video-edit")

        form.prompt = ""
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Say what should change")
    }

    @Test func extendAddsItsLengthAndKeepsTheWholeRangeInADraft() throws {
        try CostText.$locale.withValue(.enUS) {
            var form = seedance(.extend)
            form.length = 40
            #expect(form.showsAddedLength)
            #expect(form.addedLengthTitle == "Add 4–30 s")
            #expect(form.generatesAudio)
            #expect(!form.showsDraftLength)
            form.draftLength = .firstFiveSeconds

            let draft = try #require(form.makeSpecs(isDraft: true).first)
            #expect(draft.length == 30)
            #expect(draft.duration == 30)
            #expect(draft.source?.range == 0...14.2)
            // With an API key the source selection and the added part are billed together.
            #expect(form.billedSeconds(on: .apiKey) == 45)
            #expect(form.costLine(in: CreateFixture.apiKey)?.text == "45 s = $12.48")
        }
    }

    /// The account bills only the part Extend adds: a 4 s extension of a 4 s clip cost 12 credits, 4 s at 3 a second,
    /// in a live run on 2026-10-15.
    @Test func extendOnTheAccountBillsOnlyTheAddedPart() throws {
        try CostText.$locale.withValue(.enUS) {
            var form = seedance(.extend)
            form.length = 4
            let spec = try #require(form.makeSpecs(isDraft: false).first)
            var context = CreateContext(connection: .account(AccountInfo(credits: 100)))
            context.estimates[spec] = .credits(12, isEstimate: false)

            #expect(form.billedSeconds(on: .account) == 4)
            #expect(form.trimSummary(on: .account) == "14.2 s selected · billed 4 s")
            #expect(form.costLine(in: context)?.text.hasPrefix("4 s") == true)
            #expect(Pricing.billedSeconds(for: spec, on: .account) == 4)
            #expect(Pricing.billedSeconds(for: spec, on: .apiKey) == 19)
        }
    }

    @Test func switchingToEditOrExtendEndsABatch() {
        var form = seedance()
        form.isBatch = true
        form.mode = .extend
        #expect(!form.isBatch)
        #expect(form.makeSpecs(isDraft: false).count == 1)
    }

    /// Opening an Extend of a result selects up to its last 30 s and reaches the end of the file as probed, even
    /// when the result runs a little longer than asked for.
    @Test func loadingAnExtendOfAResultEndsAtTheEndOfTheFile() throws {
        let job = Job(
            spec: JobSpec(
                mode: .motionTransfer, model: .seedance25, source: nil, prompt: "a fox", resolution: .p720, length: 8),
            providerKind: .apiKey, cost: .usd(1, isEstimate: true))
        var finished = job
        finished.outputFile = URL(fileURLWithPath: "/tmp/result.mp4")
        let spec = try #require(finished.followUp(.extend))
        #expect(spec.mode == .extend)
        #expect(spec.model == .seedance25)
        #expect(spec.source?.range == 0...8)
        #expect(spec.length == CreateForm.defaultLength)
        #expect(job.followUp(.extend) == nil)
        #expect(finished.followUp(.motionTransfer) == nil)

        var form = CreateForm(mode: .motionTransfer, resolution: .p480)
        form.load(spec, source: CreateFixture.video(duration: 8.04, name: "result.mp4"), parentID: job.id)
        #expect(form.mode == .extend)
        #expect(form.range == 0...8.04)
        #expect(form.parentID == job.id)

        let edit = try #require(finished.followUp(.edit))
        form.load(edit, source: CreateFixture.video(duration: 8.04, name: "result.mp4"), parentID: job.id)
        #expect(form.range == 0...8)
    }
}
