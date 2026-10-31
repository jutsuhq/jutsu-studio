import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Genjutsu Lite in Create, templates, the queue and the agent tools (issue #15): offered on an account next to
/// Genjutsu, not with an API key, where what was saved with it falls back to Genjutsu and says so.
@Suite struct GenjutsuLiteFormTests {
    static let lite = VideoModel(rawValue: "genjutsuLite") ?? .genjutsu

    static func context(_ connection: ConnectionState, models: Set<VideoModel>) -> CreateContext {
        var context = CreateContext(connection: connection, pricing: CreateFixture.pricing)
        context.capabilities = Capabilities(
            modes: [.motionTransfer, .objectSwap], models: models, resolutions: Set(Resolution.allCases),
            costUnit: connection.kind == .account ? .credits : .usd, maxConcurrency: nil)
        return context
    }

    static let account = context(
        .account(AccountInfo(credits: 1000)), models: Set(VideoModel.allCases.filter { !$0.modes.isEmpty }))
    static let apiKey = context(.apiKey(keyID: "kid"), models: Set(VideoModel.allCases.filter(\.runsWithAPIKey)))

    @Test func theAccountOffersItNextToGenjutsuForMotionAndSwap() {
        for mode in [Mode.motionTransfer, .objectSwap] {
            var form = CreateFixture.ready()
            form.mode = mode
            #expect(Array(form.modelOptions(in: Self.account).prefix(2)) == [.genjutsu, Self.lite])
            #expect(!form.modelOptions(in: Self.apiKey).contains(Self.lite))
        }
        var restyle = CreateFixture.ready()
        restyle.mode = .restyle
        #expect(!restyle.modelOptions(in: Self.account).contains(Self.lite))
    }

    /// A 20 s clip is cut to Lite's 15 s; Genjutsu takes it whole.
    @Test func theSelectionKeepsToLitesLength() {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.model = Self.lite
        form.setSource(CreateFixture.video(duration: 20))
        #expect(form.range == 0...15)
        var genjutsu = CreateForm(mode: .motionTransfer, resolution: .p720)
        genjutsu.setSource(CreateFixture.video(duration: 20))
        #expect(genjutsu.range == 0...20)
    }

    @Test func aTemplateSavedWithLiteOpensWithLite() {
        var form = CreateFixture.ready()
        form.model = Self.lite
        let template = form.makeTemplate(name: "Cheap dance")
        #expect(template.model == Self.lite)
        #expect(template.summary.hasPrefix("\(Mode.motionTransfer.shortTitle) · Genjutsu Lite · "))

        var opened = CreateFixture.ready()
        #expect(opened.apply(template, offered: Self.account.offeredModels) == nil)
        #expect(opened.makeSpecs(isDraft: true, in: Self.account).map(\.model) == [Self.lite])
    }

    @Test func withAnAPIKeyATemplateFallsBackToGenjutsuAndSaysSo() {
        let template = JobTemplate(name: "Cheap dance", mode: .objectSwap, model: Self.lite, resolution: .p720)
        var form = CreateFixture.ready()
        let message = form.apply(template, offered: Self.apiKey.offeredModels)
        #expect(form.model == .genjutsu)
        #expect(message?.title == "Running on Genjutsu")
        #expect(message?.message == "\"Cheap dance\" uses Genjutsu Lite, which this connection doesn't offer.")
    }

    /// A draft opened again (Edit Inputs, Render final) keeps Lite where it runs and says when it can't.
    @Test func reopenedInputsFallBackToGenjutsuAndSaySo() {
        var form = CreateFixture.ready()
        form.model = Self.lite
        let draft = form.makeSpecs(isDraft: true, in: Self.account)[0]
        #expect(draft.model == Self.lite && draft.isDraft)

        var reopened = CreateForm()
        reopened.load(draft, source: CreateFixture.video())
        #expect(reopened.fitModel(to: Self.account.offeredModels) == nil)
        #expect(reopened.model == Self.lite)
        let message = reopened.fitModel(to: Self.apiKey.offeredModels)
        #expect(reopened.model == .genjutsu)
        #expect(message?.title == "Running on Genjutsu")
        #expect(message?.message == "These inputs use Genjutsu Lite, which this connection doesn't offer.")
    }

    @Test func theAllowanceNamesItsModes() {
        let capabilities = Capabilities(
            modes: [.motionTransfer], models: [.genjutsu, Self.lite], resolutions: Set(Resolution.allCases),
            costUnit: .credits, maxConcurrency: nil, unlimited: [Self.lite: [.motionTransfer]])
        #expect(capabilities.unlimitedText == "Genjutsu Lite Motion transfer")
    }

    /// The picker and Draft offer each mode what it renders at: Motion Transfer 480p, 720p and 1080p, from the
    /// form's 480p; Object Swap 720p and 1080p, so the form's 480p and the 480p draft are made at 720p there.
    @Test func eachModeOffersItsOwnResolutions() {
        var form = CreateFixture.ready(.p480)
        form.model = Self.lite
        #expect(form.resolutionOptions == Resolution.standard)
        #expect(form.pickedResolution == .p480 && form.draftTitle == "Draft 480p")
        #expect(form.makeSpecs(isDraft: false, in: Self.account).map(\.resolution) == [.p480])
        #expect(form.makeSpecs(isDraft: true, in: Self.account).map(\.resolution) == [.p480])

        form.mode = .objectSwap
        form.model = Self.lite
        #expect(form.selectedModel == Self.lite)
        #expect(form.resolutionOptions == [.p720, .p1080])
        #expect(form.pickedResolution == .p720 && form.draftTitle == "Draft 720p")
        #expect(form.makeSpecs(isDraft: false, in: Self.account).map(\.resolution) == [.p720])
        #expect(form.makeSpecs(isDraft: true, in: Self.account).map(\.resolution) == [.p720])
        form.pickedResolution = .p1080
        #expect(form.makeSpecs(isDraft: false, in: Self.account).map(\.resolution) == [.p1080])
        // Back on Motion Transfer the 1080p picked stays.
        form.mode = .motionTransfer
        form.model = Self.lite
        #expect(form.pickedResolution == .p1080)
    }

    /// An agent gets the same per-mode resolutions: 480p is refused for Object Swap, and left out it is 720p there.
    @Test func anAgentGetsEachModesResolutions() throws {
        let source = AgentVideoOrder.Source(video: CreateFixture.video(duration: 20), start: 0, end: 12)
        let images = [LocalImage(fileURL: CreateFixture.image(0))]
        let base = CreateForm(mode: .motionTransfer, resolution: .p480)
        var swap = AgentVideoOrder(
            mode: "object_swap", model: "genjutsuLite", prompt: "", source: source, images: images, resolution: "480p")
        guard case .failure(let refusal) = swap.spec(from: base, in: Self.account) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.message == "Genjutsu Lite renders at 720p, 1080p in object_swap, not 480p.")
        swap.resolution = nil
        #expect(try swap.spec(from: base, in: Self.account).get().resolution == .p720)
        swap.isDraft = true
        #expect(try swap.spec(from: base, in: Self.account).get().resolution == .p720)

        let motion = AgentVideoOrder(
            mode: "motion_transfer", model: "genjutsuLite", prompt: "", source: source, images: images,
            resolution: "480p")
        #expect(try motion.spec(from: base, in: Self.account).get().resolution == .p480)
    }

    /// Genjutsu Lite takes no aspect ratio and picks the frame itself, so quote says "model" and what to check.
    @Test func aQuoteSaysTheModelPicksTheFrame() throws {
        let order = AgentVideoOrder(
            mode: "motion_transfer", model: "genjutsuLite", prompt: "",
            source: AgentVideoOrder.Source(video: CreateFixture.video(duration: 20), start: 0, end: 12),
            images: [LocalImage(fileURL: CreateFixture.image(0))])
        let spec = try order.spec(from: CreateForm(mode: .motionTransfer, resolution: .p720), in: Self.account).get()
        #expect(AgentVideoOrder.frame(of: spec) == "model")
        #expect(AgentVideoOrder.frameNote(of: spec)?.contains("width and height") == true)
        var other = spec
        other.model = .genjutsu
        #expect(AgentVideoOrder.frame(of: other) == "source" && AgentVideoOrder.frameNote(of: other) == nil)
    }

    @Test func anAgentCanPickIt() throws {
        let order = AgentVideoOrder(
            mode: "object_swap", model: "genjutsuLite", prompt: "",
            source: AgentVideoOrder.Source(video: CreateFixture.video(duration: 20), start: 0, end: 12),
            images: [LocalImage(fileURL: CreateFixture.image(0))])
        let base = CreateForm(mode: .motionTransfer, resolution: .p720)
        #expect(try order.spec(from: base, in: Self.account).get().model == Self.lite)
        guard case .failure(let refusal) = order.spec(from: base, in: Self.apiKey) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal.message == "Genjutsu Lite isn't available on this connection.")

        var long = order
        long.source = AgentVideoOrder.Source(video: CreateFixture.video(duration: 20), start: 0, end: 18)
        guard case .failure(let tooLong) = long.spec(from: base, in: Self.account) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(tooLong.message.contains("too long"))
    }
}
