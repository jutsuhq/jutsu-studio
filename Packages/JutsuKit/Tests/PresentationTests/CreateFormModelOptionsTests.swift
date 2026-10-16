import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateFormModelOptionsTests {
    /// Every model and parameter offered, with the bundled list prices.
    static let apiKey: CreateContext = {
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases), resolutions: Set(Resolution.allCases),
            costUnit: .usd, maxConcurrency: nil)
        return context
    }()

    /// An account that runs every model but sends none of the parameters.
    static let account: CreateContext = {
        var context = CreateContext(connection: .account(AccountInfo(credits: 1000)))
        context.capabilities = Capabilities(
            modes: [.motionTransfer, .objectSwap], models: Set(VideoModel.allCases),
            resolutions: Set(Resolution.allCases), costUnit: .credits, maxConcurrency: nil, parameters: [])
        return context
    }()

    static func seedanceWithoutSource() -> CreateForm {
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.model = .seedance25
        form.prompt = "A fox turns to the camera"
        return form
    }

    static let start = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/start.png"))
    static let end = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/end.png"))

    // MARK: Audio

    @Test func seedanceWithASourceCanMakeItsOwnSound() throws {
        var form = CreateFixture.ready()
        #expect(form.audioChoices == [.original, .mute, .fadeOut])
        form.model = .seedance25
        #expect(form.audioChoices == [.original, .mute, .fadeOut, .generated])
        #expect(form.audioDetail == "From the source")

        form.audio = .generated
        #expect(form.audioDetail == "Made by Seedance 2.5")
        #expect(try #require(form.makeSpecs(isDraft: false).first).audio == .generated)

        form.mode = .extend
        #expect(!form.offersGeneratedAudio)
        form.mode = .motionTransfer
        form.model = .klingMotionControl
        #expect(!form.audioChoices.contains(.generated))
        #expect(form.audioDetail == "From the source")
        #expect(try #require(form.makeSpecs(isDraft: false).first).audio == .original)
    }

    // MARK: Bitrate and orientation

    @Test func seedanceHasABitrateAndKlingAnOrientation() throws {
        var form = CreateFixture.ready()
        #expect(!form.showsBitrate && !form.showsCharacterOrientation)
        var spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.bitrate == nil && spec.characterOrientation == nil)

        form.model = .seedance25
        #expect(form.showsBitrate)
        spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.bitrate == nil)
        form.setBitrate(.standard)
        spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.bitrate == .standard && spec.characterOrientation == nil)

        form.model = .klingMotionControl
        #expect(form.showsCharacterOrientation && form.characterOrientation == .video)
        form.characterOrientation = .image
        spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.characterOrientation == .image && spec.bitrate == nil)
        #expect(SeedanceBitrate.allCases.map(\.title) == ["Standard", "High bitrate"])
        #expect(CharacterOrientation.allCases.map(\.title) == ["As in image", "As in video"])

        var reopened = CreateForm()
        reopened.load(spec, source: CreateFixture.video())
        #expect(reopened.characterOrientation == .image)
    }

    /// Until picked, the picker shows what each server does with no bitrate: Standard on the account, High with an
    /// API key; nothing is sent, so the default stays the server's.
    @Test func theBitrateDefaultsToTheConnectionsOwn() throws {
        var form = Self.seedanceWithoutSource()
        #expect(form.bitrate(on: .account) == .standard)
        #expect(form.bitrate(on: .apiKey) == .high)
        #expect(try #require(form.makeSpecs(isDraft: false).first).bitrate == nil)

        form.setBitrate(.high)
        #expect(form.bitrate(on: .account) == .high)
        #expect(try #require(form.makeSpecs(isDraft: false).first).bitrate == .high)
    }

    /// A connection that can't send a parameter has Create disable its control with the reason; an API key sends
    /// all of them. The account never sends Kling's sound or orientation: its model has neither.
    @Test func unsentParametersSayWhyOnTheAccount() {
        for parameter in ModelParameter.allCases {
            #expect(Self.apiKey.unavailableReason(for: parameter) == nil)
            #expect(Self.account.unavailableReason(for: parameter) != nil)
        }
        #expect(CreateFixture.apiKey.unavailableReason(for: .seedanceFrames) == nil)
        #expect(
            Self.account.unavailableReason(for: .klingOrientation)
                == "Kling's character orientation is set only with an API key, not on the account")
        #expect(
            Self.account.unavailableReason(for: .klingOriginalSound)
                == "Kling keeps the source's sound on the server only with an API key, not on the account")
    }

    /// The control's tooltip gives the reason in a few words, only where there is one.
    @Test func unsentParametersHaveAShortHint() {
        for parameter in ModelParameter.allCases {
            #expect(Self.apiKey.unavailableHint(for: parameter) == nil)
        }
        #expect(Self.account.unavailableHint(for: .klingOrientation) == "Only with an API key")
        #expect(Self.account.unavailableHint(for: .klingVideoBackground) == "Not available for this account")
    }

    // MARK: Frames

    @Test func framesRunOnImageToVideoAndSetReferencesAside() throws {
        try CostText.$locale.withValue(.enUS) {
            var form = Self.seedanceWithoutSource()
            form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
            form.aspectRatio = .portrait
            #expect(form.showsFrames && !form.usesFrames)
            #expect(form.referencesDisabledReason == nil)

            form.setFrame(Self.start, for: .start)
            form.setFrame(Self.end, for: .end)
            #expect(form.usesFrames)
            #expect(form.referencesDisabledReason != nil)
            #expect(form.blocker(isDraft: false, in: Self.apiKey) == nil)
            let spec = try #require(form.makeSpecs(isDraft: false).first)
            #expect(spec.references == [Self.start, Self.end])
            #expect(spec.referencesAreFrames && spec.usesFrames)
            #expect(spec.aspectRatio == nil)
            #expect(spec.endpointID == "bytedance/seedance-2.5/image-to-video")
            // 5 s at 720p, priced like a clip without video input.
            #expect(form.priceText(isDraft: false, in: Self.apiKey) == "$2.31")
            #expect(form.rateText(in: Self.apiKey) == "$0.462 / s")

            var reopened = CreateForm()
            reopened.load(spec, source: nil)
            #expect(reopened.frame(.start) == Self.start && reopened.frame(.end) == Self.end)
            #expect(reopened.references.isEmpty)
            #expect(reopened.makeSpecs(isDraft: false) == [spec])

            form.setFrame(nil, for: .start)
            form.setFrame(nil, for: .end)
            let withReferences = try #require(form.makeSpecs(isDraft: false).first)
            #expect(!withReferences.referencesAreFrames && withReferences.references.count == 1)
            #expect(withReferences.aspectRatio == .portrait)
        }
    }

    @Test func anEndFrameAloneCantRun() {
        var form = Self.seedanceWithoutSource()
        form.setFrame(Self.end, for: .end)
        #expect(form.blocker(isDraft: false, in: Self.apiKey) == "Add a start frame, or clear the end frame")
    }

    /// A connection whose capabilities leave the frames out blocks them with the reason.
    @Test func framesNeedTheConnectionToSendThem() {
        var form = Self.seedanceWithoutSource()
        form.setFrame(Self.start, for: .start)
        #expect(
            form.blocker(isDraft: false, in: Self.account)
                == Self.account.unavailableReason(for: .seedanceFrames))
    }

    /// Frames are for a clip made without a source on Seedance, outside a batch.
    @Test func framesNeedSeedanceWithoutASource() throws {
        var form = Self.seedanceWithoutSource()
        form.setFrame(Self.start, for: .start)
        form.setSource(CreateFixture.video())
        #expect(!form.showsFrames && !form.usesFrames)
        #expect(try #require(form.makeSpecs(isDraft: false).first).referencesAreFrames == false)

        form.setSource(nil)
        form.model = .genjutsu
        #expect(!form.showsFrames)
        form.model = .seedance25
        form.isBatch = true
        #expect(!form.showsFrames)
    }

    // MARK: Templates and drafts

    @Test func templatesCarryTheModelParameters() {
        var form = Self.seedanceWithoutSource()
        form.setBitrate(.standard)
        form.setFrame(Self.start, for: .start)
        let template = form.makeTemplate(name: "Frames")
        #expect(template.referencesAreFrames && template.references == [Self.start])
        #expect(template.bitrate == .standard)
        #expect(template.summary == "Motion · Seedance 2.5 · Start frame · 720p")

        var applied = CreateForm()
        applied.apply(template, offered: Set(VideoModel.allCases))
        #expect(applied.frame(.start) == Self.start && applied.references.isEmpty)
        #expect(applied.bitrate(on: .apiKey) == .standard)
        #expect(applied.makeSpecs(isDraft: false) == form.makeSpecs(isDraft: false))

        var kling = CreateFixture.ready()
        kling.model = .klingMotionControl
        kling.characterOrientation = .image
        var appliedKling = CreateForm()
        appliedKling.apply(kling.makeTemplate(name: "Kling"), offered: Set(VideoModel.allCases))
        #expect(appliedKling.characterOrientation == .image)
    }

    @Test func aDraftSavedBeforeTheModelParametersStillDecodes() throws {
        var form = Self.seedanceWithoutSource()
        form.setBitrate(.standard)
        form.setFrame(Self.start, for: .start)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(form))
        var object = try #require(encoded as? [String: Any])
        for key in ["seedanceBitrate", "startFrame"] {
            #expect(object.removeValue(forKey: key) != nil)
        }
        let old = try JSONDecoder().decode(CreateForm.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.bitrate(on: .apiKey) == .high && old.frame(.start) == nil)
        #expect(try JSONDecoder().decode(CreateForm.self, from: JSONEncoder().encode(form)) == form)
    }

    @Test func framesAreInputsOfTheDraft() {
        var form = CreateForm()
        #expect(!form.hasInputs)
        form.setFrame(Self.start, for: .start)
        #expect(form.hasInputs)
        #expect(CreateForm().dropsInputs(of: form))
        #expect(form.reopeningFiles { _ in nil }.frame(.start) == nil)
        #expect(form.reopeningFiles { $0 }.frame(.start) == Self.start)
    }
}
