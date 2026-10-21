import Foundation
import JutsuCore
import Testing

@testable import Presentation

enum CreateFixture {
    static func video(
        duration: TimeInterval = 14.2, width: Int = 1920, height: Int = 1080, codec: String = "avc1",
        name: String = "clip.mp4"
    ) -> SourceVideo {
        SourceVideo(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"), duration: duration,
            pixelSize: PixelSize(width: width, height: height), codec: codec, fileSize: 38_000_000)
    }

    static func image(_ index: Int) -> URL { URL(fileURLWithPath: "/tmp/ref\(index).png") }

    static func references(_ urls: [URL]) -> [LocalImage] { urls.map { LocalImage(fileURL: $0) } }

    /// Genjutsu at $0.318, $0.681 and $1.632 per second.
    static let pricing = try! Pricing.bundled()

    static let apiKey = CreateContext(connection: .apiKey(keyID: "kid"), pricing: pricing)

    /// Motion transfer with a 14.2 s clip and one image: submittable.
    static func ready(_ resolution: Resolution = .p720) -> CreateForm {
        var form = CreateForm(mode: .motionTransfer, resolution: resolution)
        form.setSource(video())
        form.addReferences(CreateFixture.references([image(1)]))
        return form
    }
}

@Suite struct CreateFormRangeTests {
    @Test func shortClipIsSelectedWhole() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 14.2))
        #expect(form.range == 0...14.2)
    }

    @Test func longClipSelectsTheFirst30Seconds() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateForm()
            form.setSource(CreateFixture.video(duration: 47.3))
            #expect(form.range == 0...30)
            #expect(form.stagePills.contains("47.3 s clip — pick up to 30 s below"))
        }
    }

    @Test func handlesKeepTheLengthWithin4To30Seconds() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 47.5))
        form.setStart(28)
        #expect(form.range == 26...30)
        form.setEnd(100)
        #expect(form.range == 26...47.5)
        form.setStart(0)
        #expect(form.range == 17.5...47.5)
        form.setEnd(10)
        #expect(form.range == 17.5...21.5)
    }

    @Test func movingKeepsTheLengthInsideTheClip() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 47.5))
        form.setEnd(10)
        form.moveRange(toStart: 45)
        #expect(form.range == 37.5...47.5)
        form.moveRange(toStart: -3)
        #expect(form.range == 0...10)
    }

    @Test func clipShorterThan4SecondsStaysWholeAndBlocks() {
        var form = CreateFixture.ready()
        form.setSource(CreateFixture.video(duration: 3))
        form.setStart(1)
        form.setEnd(2)
        #expect(form.range == 0...3)
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Pick at least 4 s of video")
    }

    @Test func trimTexts() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateForm()
            form.setSource(CreateFixture.video(duration: 47.3))
            form.setStart(6)
            form.setEnd(18.5)
            #expect(form.rangeText == "00:06.0 – 00:18.5")
            #expect(form.trimSummary(on: .apiKey) == "12.5 s selected · billed 13 s")
            #expect(CostText.timecode(66.54) == "01:06.5")
        }
    }
}

@Suite struct CreateFormReferenceTests {
    @Test func limitsFollowTheMode() {
        var form = CreateForm(mode: .motionTransfer)
        let added = form.addReferences(CreateFixture.references((1...10).map(CreateFixture.image)))
        #expect(added == 8)
        #expect(!form.canAddReferences)
        #expect(form.referenceCountText == "8 / 8")
        form.mode = .restyle
        #expect(form.references.count == 5)
        #expect(form.referenceCountText == "5 / 5")
        form.mode = .objectSwap
        #expect(form.referenceLimits == 1...8)
        #expect(form.references.count == 5)
    }

    @Test func duplicatesAreSkipped() {
        var form = CreateForm()
        form.addReferences(
            CreateFixture.references([CreateFixture.image(1), CreateFixture.image(1), CreateFixture.image(2)]))
        #expect(form.references.map(\.fileURL) == [CreateFixture.image(1), CreateFixture.image(2)])
    }

    @Test func sameFileWithAnotherBookmarkIsADuplicate() {
        var form = CreateForm()
        form.addReferences([LocalImage(fileURL: CreateFixture.image(1), bookmark: Data([1]))])
        let added = form.addReferences([LocalImage(fileURL: CreateFixture.image(1), bookmark: Data([2]))])
        #expect(added == 0)
        #expect(form.references == [LocalImage(fileURL: CreateFixture.image(1), bookmark: Data([1]))])
    }

    @Test func reorderAndRemove() {
        var form = CreateForm()
        form.addReferences(CreateFixture.references((1...3).map(CreateFixture.image)))
        form.moveReference(at: 0, to: 2)
        #expect(form.references.map(\.fileURL) == [2, 3, 1].map(CreateFixture.image))
        form.moveReference(at: 2, to: -5)
        #expect(form.references.map(\.fileURL) == [1, 2, 3].map(CreateFixture.image))
        form.removeReference(at: 1)
        form.removeReference(at: 9)
        #expect(form.references.map(\.fileURL) == [1, 3].map(CreateFixture.image))
    }
}

@Suite struct CreateFormBlockerTests {
    @Test func connectionAndSourceComeFirst() {
        let disconnected = CreateContext(connection: .none)
        #expect(CreateFixture.ready().blocker(isDraft: false, in: disconnected) == "Connect Higgsfield in Settings")
        #expect(CreateForm().blocker(isDraft: false, in: CreateFixture.apiKey) == "Add a source video")
    }

    @Test func modeTheConnectionCantRun() {
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: [.restyle], resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil)
        #expect(CreateFixture.ready().blocker(isDraft: false, in: context) == "Not available with this API key")
    }

    @Test func modelPickerOffersTheAccountModelsForMotionOnly() {
        var context = CreateContext(connection: .account(AccountInfo()))
        #expect(CreateFixture.ready().modelOptions(in: context) == [.genjutsu])
        context.capabilities = Capabilities(
            modes: [.motionTransfer, .objectSwap], models: Set(VideoModel.allCases),
            resolutions: Set(Resolution.allCases), costUnit: .credits, maxConcurrency: nil)
        var form = CreateFixture.ready()
        #expect(form.modelOptions(in: context) == VideoModel.allCases.filter { $0.serves(.motionTransfer) })

        form.model = .seedance25
        #expect(form.makeSpecs(isDraft: false).map(\.model) == [.seedance25])
        form.mode = .objectSwap
        #expect(form.modelOptions(in: context) == VideoModel.allCases.filter { $0.serves(.objectSwap) })
        #expect(form.modelOptions(in: context).map(\.rawValue) == ["genjutsu", "genjutsuLite"])
        #expect(form.makeSpecs(isDraft: false).map(\.model) == [.genjutsu])
        form.mode = .motionTransfer
        #expect(form.selectedModel == .seedance25)
    }

    @Test func seedanceQueuesAClipWithoutASource() throws {
        var context = CreateContext(connection: .account(AccountInfo()))
        context.capabilities = Capabilities(
            modes: [.motionTransfer, .objectSwap], models: Set(VideoModel.allCases),
            resolutions: Set(Resolution.allCases), costUnit: .credits, maxConcurrency: nil)
        var form = CreateForm(mode: .motionTransfer, resolution: .p720, draftResolution: .p480)
        #expect(!form.isWithoutSource)
        #expect(form.blocker(isDraft: false, in: context) == "Add a source video")
        #expect(form.makeSpecs(isDraft: false).isEmpty)

        form.model = .seedance25
        #expect(form.isWithoutSource)
        #expect(form.promptTitle == "Prompt")
        #expect(form.blocker(isDraft: false, in: context) == "Write a prompt or add an image")
        form.prompt = "A fox runs through fresh snow"
        form.length = 40
        form.aspectRatio = .portrait
        #expect(form.blocker(isDraft: false, in: context) == nil)

        let spec = try #require(form.makeSpecs(isDraft: false).first)
        #expect(spec.source == nil)
        #expect(spec.length == 30)
        #expect(spec.aspectRatio == .portrait)
        #expect(spec.references.isEmpty)
        let draft = form.makeSpecs(isDraft: true).first
        #expect(draft?.resolution == .p480 && draft?.length == 30)
        #expect(form.draftDuration == 30)
        #expect(form.costLine(in: context)?.text == "30 s · estimating…")

        var reopened = CreateForm()
        reopened.load(spec, source: nil)
        #expect(reopened.isWithoutSource && reopened.length == 30 && reopened.aspectRatio == .portrait)
        #expect(reopened.makeSpecs(isDraft: false) == [spec])

        form.setSource(CreateFixture.video())
        #expect(!form.isWithoutSource)
        #expect(form.makeSpecs(isDraft: false).first?.length == nil)
        #expect(form.blocker(isDraft: false, in: context) == "Add at least one image")
    }

    @Test func modelTheConnectionCantRun() {
        var form = CreateFixture.ready()
        form.model = .klingMotionControl
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil)
        #expect(form.blocker(isDraft: false, in: context) == "Kling 3.0 isn't available on this connection")
    }

    @Test func apiKeyPricesKlingByItsQualityAndCantKeepTheBackground() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateFixture.ready()
            form.model = .klingMotionControl
            form.resolution = .p1080
            var context = CreateFixture.apiKey
            context.capabilities = Capabilities(
                modes: Set(Mode.allCases), models: Set(VideoModel.allCases), resolutions: Set(Resolution.allCases),
                costUnit: .usd, maxConcurrency: nil,
                parameters: Set(ModelParameter.allCases).subtracting([.klingVideoBackground]))

            // Motion lists the models that edit or extend a clip too.
            #expect(
                form.modelOptions(in: context)
                    == VideoModel.allCases.filter { [.motionTransfer, .edit, .extend].contains(where: $0.serves) })
            #expect(form.blocker(isDraft: false, in: context) == nil)
            #expect(form.rateText(in: context) == "$0.168 / s")
            #expect(form.costLine(in: context)?.detail == "Estimate · failed runs are free")
            #expect(
                context.videoBackgroundUnavailableReason
                    == "Kling keeps the video's background only on a Higgsfield account, not with an API key")
            #expect(CreateContext(connection: .account(AccountInfo())).videoBackgroundUnavailableReason == nil)
        }
    }

    @Test func aModelTheConnectionDoesntOfferFallsBackToGenjutsu() {
        var form = CreateFixture.ready()
        form.model = .seedance25
        form.fitModel(to: nil)
        #expect(form.model == .seedance25)
        form.fitModel(to: Set(VideoModel.allCases))
        #expect(form.model == .seedance25)
        form.fitModel(to: [.genjutsu])
        #expect(form.model == .genjutsu)
    }

    @Test func klingTakesOneReference() {
        var form = CreateFixture.ready()
        form.addReferences(CreateFixture.references((1...3).map(CreateFixture.image)))
        form.model = .klingMotionControl
        #expect(form.references.count == 1)
        #expect(!form.canAddReferences)
        #expect(form.referenceCountText == "1 / 1")

        form.isBatch = true
        let message = form.addCharacterSet(CreateFixture.references([CreateFixture.image(4), CreateFixture.image(5)]))
        #expect(form.characterSets.last?.count == 1)
        #expect(message?.message == "Each character takes one reference image.")
    }

    @Test func loadingAJobKeepsItsModel() {
        var spec = CreateFixture.ready().makeSpecs(isDraft: false)[0]
        spec.model = .seedance25
        var form = CreateForm()
        form.load(spec, source: CreateFixture.video())
        #expect(form.model == .seedance25)
    }

    @Test func clampCutsReferencesAndBringsRangesInsideTheLimits() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 60))
        form.addReferences(CreateFixture.references((1...4).map(CreateFixture.image)))
        form.setEnd(20)
        form.addRange()
        form.setStart(25)
        form.setEnd(27)
        #expect(form.ranges == [0...20, 25...29])

        form.clamp(to: ModeLimits(referenceImages: 1...2, requiresPreset: false, duration: 6...12))

        #expect(form.references == CreateFixture.references([CreateFixture.image(1), CreateFixture.image(2)]))
        #expect(form.ranges == [0...12, 25...31])
    }

    @Test func clampGrowsARangeOnlyIntoItsRoom() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(duration: 30))
        form.setEnd(10)
        form.addRange()
        form.setStart(14)
        form.setEnd(30)
        #expect(form.ranges == [0...10, 14...30])

        form.clamp(to: ModeLimits(referenceImages: 0...8, requiresPreset: false, duration: 12...20))

        #expect(form.ranges == [0...12, 14...30])
    }

    @Test func changingTheModelKeepsTheFormInsideItsLimits() {
        var form = CreateFixture.ready()
        form.setSource(CreateFixture.video(duration: 47))
        form.addReferences(CreateFixture.references((1...8).map(CreateFixture.image)))
        for model in VideoModel.allCases where model.serves(.motionTransfer) {
            form.model = model
            let limits = model.limits(for: .motionTransfer)
            #expect(form.limits == limits)
            #expect(limits.referenceImages.contains(form.references.count))
            #expect(form.ranges.allSatisfy { limits.duration.contains($0.upperBound - $0.lowerBound) })
            #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) != "Pick at most 30 s of video")
        }
    }

    @Test func durationIssuesNameTheLimit() {
        var form = CreateFixture.ready()
        form.setSource(CreateFixture.video(duration: 3))
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Pick at least 4 s of video")
    }

    @Test func validationIssuesReadAsActions() {
        var form = CreateForm()
        form.setSource(CreateFixture.video())
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Add at least one image")
        form.mode = .restyle
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Pick a style")
        form.presetID = UUID()
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == nil)
        form.prompt = String(repeating: "a", count: 10_001)
        #expect(form.promptCounterText == "10001 / 10 000")
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Shorten the prompt to 10 000 characters")
    }

    @Test func smallSwapFrameNeedsTheUpscale() {
        var form = CreateForm(mode: .objectSwap)
        form.setSource(CreateFixture.video(duration: 11.4, width: 720, height: 480))
        form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
        #expect(
            form.blocker(isDraft: false, in: CreateFixture.apiKey) == "Object swap needs 640×640 px, allow the upscale")
        #expect(form.upscaleNotice?.title == "720×480 is below the 640×640 minimum for object swap.")
        #expect(form.upscaleNotice?.detail.hasPrefix("Upscale to 784×524 before upload?") == true)
        form.allowsUpscale = true
        #expect(form.blocker(isDraft: false, in: CreateFixture.apiKey) == nil)
        #expect(form.stagePills.contains("Will upscale to 784×524"))
        #expect(form.makeSpecs(isDraft: false).first?.source?.allowsUpscale == true)
        form.mode = .motionTransfer
        #expect(!form.allowsUpscale)
        #expect(form.upscaleNotice == nil)
    }

    @Test func largeSwapFrameHasNoNotice() {
        var form = CreateForm(mode: .objectSwap)
        form.setSource(CreateFixture.video())
        #expect(form.upscaleNotice == nil)
        form.allowsUpscale = true
        #expect(form.makeSpecs(isDraft: false).first?.source?.allowsUpscale == false)
    }

    @Test func notEnoughCreditsForTheDraft() throws {
        let form = CreateFixture.ready()
        let draft = try #require(form.makeSpecs(isDraft: true).first)
        var context = CreateContext(
            connection: .account(AccountInfo(credits: 50)), estimates: [draft: .credits(60, isEstimate: true)])
        #expect(form.blocker(isDraft: true, in: context) == "Not enough credits on your plan")
        context.estimates[draft] = .credits(40, isEstimate: true)
        #expect(form.blocker(isDraft: true, in: context) == nil)
    }

    @Test func generateIsCheckedAgainstTheFullRenderCost() throws {
        let form = CreateFixture.ready()
        let draft = try #require(form.makeSpecs(isDraft: true).first)
        let full = try #require(form.makeSpecs(isDraft: false).first)
        let context = CreateContext(
            connection: .account(AccountInfo(credits: 50)),
            estimates: [draft: .credits(40, isEstimate: true), full: .credits(96, isEstimate: true)])
        #expect(form.blocker(isDraft: true, in: context) == nil)
        let reason = "Not enough credits for Generate, try a draft"
        #expect(form.blocker(isDraft: false, in: context) == reason)
        #expect(form.submitDecision(isDraft: false, in: context) == .blocked(reason))
        #expect(form.submitDecision(isDraft: true, in: context) == .start([draft]))
    }
}

@Suite struct CreateFormCostTests {
    @Test func usdCostLineUsesTheListPrice() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateFixture.ready(.p720)
            form.setSource(CreateFixture.video(duration: 47.3))
            form.setEnd(12.4)
            let line = form.costLine(in: CreateFixture.apiKey)
            #expect(line?.text == "13 s × $0.681 = $8.85")
            #expect(line?.detail == "List price · failed runs are free")
            #expect(line?.isWarning == false)
            #expect(form.priceText(isDraft: false, in: CreateFixture.apiKey) == "$8.85")
            #expect(form.rateText(in: CreateFixture.apiKey) == "$0.681 / s")
        }
    }

    @Test func overCapWarns() {
        var context = CreateFixture.apiKey
        context.committedToday = 70
        context.cap = .usd(75)
        let line = CreateFixture.ready().costLine(in: context)
        #expect(line?.detail == "Over today's cap, you'll be asked to confirm")
        #expect(line?.isWarning == true)
    }

    @Test func creditsCostLineUsesTheEstimate() {
        let form = CreateFixture.ready()
        let spec = form.makeSpecs(isDraft: false).first!
        var context = CreateContext(connection: .account(AccountInfo(credits: 1240)))
        #expect(form.costLine(in: context)?.text == "15 s · estimating…")
        #expect(form.priceText(isDraft: false, in: context) == nil)
        #expect(form.rateText(in: context) == nil)
        context.estimates[spec] = .credits(120, isEstimate: true)
        #expect(form.costLine(in: context)?.text == "15 s = 120 credits")
        #expect(
            form.costLine(in: context)?.detail
                == "Estimate, Higgsfield quotes it after upload · 1240 cr left on your plan · failed runs are free")
        #expect(form.priceText(isDraft: false, in: context) == "120 cr")
        // Higgsfield's `get_cost` quote before upload.
        context.estimates[spec] = .credits(105, isEstimate: false)
        #expect(form.costLine(in: context)?.text == "15 s = 105 credits")
        #expect(
            form.costLine(in: context)?.detail
                == "Price from Higgsfield · 1240 cr left on your plan · failed runs are free")
        #expect(form.priceText(isDraft: false, in: context) == "105 cr")
    }

    @Test func draftIs480pAndCanBeShortened() {
        CostText.$locale.withValue(.enUS) {
            var form = CreateFixture.ready(.p1080)
            #expect(form.showsDraftLength)
            #expect(form.priceText(isDraft: true, in: CreateFixture.apiKey) == "$4.77")
            form.draftLength = .firstFiveSeconds
            #expect(form.draftDuration == 5)
            #expect(form.draftLengthDetail(in: CreateFixture.apiKey) == "5.0 s · $1.59")
            let draft = form.makeSpecs(isDraft: true).first
            #expect(draft?.resolution == .p480)
            #expect(draft?.isDraft == true)
            #expect(draft?.source?.range == 0...5)
            #expect(form.makeSpecs(isDraft: false).first?.source?.range == 0...14.2)
        }
    }

    @Test func draftFollowsTheDraftResolutionSetting() {
        var form = CreateFixture.ready(.p1080)
        #expect(form.draftTitle == "Draft 480p")
        form.draftResolution = .p720
        #expect(form.draftTitle == "Draft 720p")
        #expect(form.makeSpecs(isDraft: true).allSatisfy { $0.resolution == .p720 && $0.isDraft })
        #expect(form.makeSpecs(isDraft: false).allSatisfy { $0.resolution == .p1080 })
        form.load(form.makeSpecs(isDraft: false)[0], source: form.source)
        #expect(form.draftResolution == .p720)
    }

    @Test func draftLengthHiddenForShortRanges() {
        var form = CreateFixture.ready()
        form.setSource(CreateFixture.video(duration: 4.5))
        form.draftLength = .firstFiveSeconds
        #expect(!form.showsDraftLength)
        #expect(form.draftDuration == 4.5)
    }

    @Test func dollarFormatting() {
        CostText.$locale.withValue(.enUS) {
            #expect(CostText.dollars(8) == "$8.00")
            #expect(CostText.dollars(Decimal(string: "3.815")!) == "$3.82")
            #expect(CostText.rate(Decimal(string: "0.3")!) == "$0.300")
            #expect(CostText.text(.credits(96, isEstimate: true)) == "96 cr")
        }
    }

    /// An image can cost half a credit; it shows so, never as a whole one.
    @Test func fractionalCreditsShowExactly() {
        CostText.$locale.withValue(Locale(identifier: "de_DE")) {
            #expect(CostText.text(.credits(0.5, isEstimate: false)) == "0.5 cr")
            #expect(CostText.text(.credits(Decimal(string: "1.125")!, isEstimate: false)) == "1.125 cr")
            // Never shown lower than the price.
            #expect(CostText.text(.credits(Decimal(string: "0.0001")!, isEstimate: false)) == "0.001 cr")
            #expect(CostText.amount(Decimal(string: "12.5")!, unit: .credits) == "12.5 credits")
        }
    }
}

@Suite struct CreateFormSpecTests {
    @Test func specCarriesTheForm() {
        var form = CreateForm(mode: .restyle, resolution: .p720)
        form.setSource(CreateFixture.video(duration: 47.3))
        form.setStart(6)
        form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
        let preset = UUID()
        form.presetID = preset
        form.prompt = "Rain"
        form.audio = .mute
        let spec = form.makeSpecs(isDraft: false).first
        #expect(spec?.mode == .restyle)
        #expect(spec?.source?.range == 6...30)
        #expect(spec?.source?.duration == 47.3)
        #expect(spec?.references == [LocalImage(fileURL: CreateFixture.image(1))])
        #expect(spec?.presetID == preset)
        #expect(spec?.prompt == "Rain")
        #expect(spec?.resolution == .p720)
        #expect(spec?.isDraft == false)
        #expect(spec?.audio == .mute)
    }

    @Test func loadingASpecRestoresTheForm() {
        var original = CreateForm(mode: .objectSwap, resolution: .p1080)
        original.setSource(CreateFixture.video(duration: 47.3, width: 720, height: 480))
        original.setStart(6)
        original.setEnd(18.5)
        original.addReferences(CreateFixture.references([CreateFixture.image(1), CreateFixture.image(2)]))
        original.prompt = "Green sneaker"
        original.allowsUpscale = true
        original.audio = .fadeOut
        let spec = original.makeSpecs(isDraft: false).first!

        var form = CreateFixture.ready()
        form.load(spec, source: CreateFixture.video(duration: 47.3, width: 720, height: 480))
        #expect(form.makeSpecs(isDraft: false).first == spec)

        form.load(spec, source: nil)
        #expect(form.source == nil)
        #expect(form.prompt == "Green sneaker")
        #expect(form.references.count == 2)
    }

    @Test func loadingALibraryItemKeepsItAsTheParentUntilTheSourceChanges() throws {
        let spec = try #require(CreateFixture.ready().makeSpecs(isDraft: false).first)
        let parent = UUID()
        var form = CreateFixture.ready()
        #expect(form.parentID == nil)

        form.load(spec, source: CreateFixture.video(), parentID: parent)
        #expect(form.parentID == parent)
        form.prompt = "changed"
        #expect(form.parentID == parent)

        form.setSource(CreateFixture.video(duration: 12))
        #expect(form.parentID == nil)

        form.load(spec, source: CreateFixture.video(), parentID: parent)
        form.load(spec, source: CreateFixture.video())
        #expect(form.parentID == nil)
    }

    @Test func specCarriesTheBookmarks() {
        var video = CreateFixture.video()
        video.bookmark = Data([1, 2])
        var form = CreateForm()
        form.setSource(video)
        form.addReferences([LocalImage(fileURL: CreateFixture.image(1), bookmark: Data([3]))])
        let spec = form.makeSpecs(isDraft: true).first
        #expect(spec?.source?.bookmark == Data([1, 2]))
        #expect(spec?.references.map(\.bookmark) == [Data([3])])
    }

    @Test func presetIsOnlySentForRestyle() {
        var form = CreateFixture.ready()
        form.presetID = UUID()
        #expect(form.makeSpecs(isDraft: false).first?.presetID == nil)
        #expect(CreateForm().makeSpecs(isDraft: false).first == nil)
    }

    @Test func conversionPill() {
        var form = CreateForm()
        form.setSource(CreateFixture.video(codec: "hvc1", name: "IMG.MOV"))
        #expect(form.stagePills == ["Will convert to MP4 · H.264"])
        #expect(form.source?.fileText == "38 MB · HEVC")
        form.setSource(CreateFixture.video())
        #expect(form.stagePills.isEmpty)
    }
}

@Suite struct SubmitDecisionTests {
    @Test func startsUnderTheCap() {
        var context = CreateFixture.apiKey
        context.cap = .usd(75)
        let form = CreateFixture.ready()
        #expect(form.submitDecision(isDraft: false, in: context) == .start(form.makeSpecs(isDraft: false)))
    }

    @Test func asksAboveTheCap() {
        CostText.$locale.withValue(.enUS) {
            var context = CreateFixture.apiKey
            context.committedToday = 70
            context.cap = .usd(75)
            let form = CreateFixture.ready()
            guard case .confirm(let specs, let confirmation) = form.submitDecision(isDraft: false, in: context) else {
                Issue.record("expected a confirmation")
                return
            }
            #expect(specs == form.makeSpecs(isDraft: false))
            #expect(confirmation.title == "Over today's spend cap")
            #expect(
                confirmation.message == "This job adds $10.22, bringing today to $80.22 against your $75.00 cap.")
            #expect(confirmation.confirmTitle == "Start anyway")
        }
    }

    @Test func draftCanFitWhereTheFinalDoesNot() {
        var context = CreateFixture.apiKey
        context.committedToday = 70
        context.cap = .usd(75)
        let form = CreateFixture.ready()
        #expect(form.submitDecision(isDraft: true, in: context) == .start(form.makeSpecs(isDraft: true)))
    }

    @Test func noCapOrAnotherUnitNeverAsks() {
        let form = CreateFixture.ready()
        var context = CreateFixture.apiKey
        context.committedToday = 1_000
        #expect(form.submitDecision(isDraft: false, in: context) == .start(form.makeSpecs(isDraft: false)))
        let spec = form.makeSpecs(isDraft: false)[0]
        let credits = CreateContext(
            connection: .account(AccountInfo()), estimates: [spec: .credits(120, isEstimate: true)],
            committedToday: 1_000, cap: .usd(1))
        #expect(form.submitDecision(isDraft: false, in: credits) == .start(form.makeSpecs(isDraft: false)))
    }

    @Test func creditCapAsksForAnAccount() {
        let form = CreateFixture.ready()
        let spec = form.makeSpecs(isDraft: false)[0]
        let context = CreateContext(
            connection: .account(AccountInfo(credits: 5_000)), estimates: [spec: .credits(120, isEstimate: true)],
            committedToday: 900, cap: .credits(1_000))
        #expect(form.costLine(in: context)?.isWarning == true)
        #expect(form.costLine(in: context)?.text == "15 s = 120 credits")
        guard case .confirm(_, let confirmation) = form.submitDecision(isDraft: false, in: context) else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(
            confirmation.message
                == "This job adds 120 credits, bringing today to 1020 credits against your 1000 credits cap.")
    }

    @Test func blockedFormSaysWhy() {
        #expect(CreateForm().submitDecision(isDraft: false, in: CreateFixture.apiKey) == .blocked("Add a source video"))
    }
}

@Suite struct BudgetedDecisionTests {
    @Test func sharedHelperAsksOnlyForUSDOverTheCap() {
        CostText.$locale.withValue(.enUS) {
            let spec = CreateFixture.ready().makeSpecs(isDraft: false).first!
            let usd = Cost.usd(10, isEstimate: false)
            #expect(SubmitDecision.budgeted([spec], cost: usd, committedToday: 60, cap: .usd(75)) == .start([spec]))
            #expect(SubmitDecision.budgeted([spec], cost: usd, committedToday: 60, cap: nil) == .start([spec]))
            let credits = Cost.credits(500, isEstimate: true)
            #expect(SubmitDecision.budgeted([spec], cost: credits, committedToday: 99, cap: .usd(75)) == .start([spec]))
            guard
                case .confirm(_, let prompt) = SubmitDecision.budgeted(
                    [spec], cost: usd, committedToday: 70, cap: .usd(75))
            else {
                Issue.record("expected a confirmation")
                return
            }
            #expect(prompt.message == "This job adds $10.00, bringing today to $80.00 against your $75.00 cap.")
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PresetCatalogTests {
    static let presets = [
        StylePreset(id: UUID(), name: "Cel-Shaded CG Anime", previewURL: URL(string: "https://example.com/a.png")!),
        StylePreset(id: UUID(), name: "Claymation", previewURL: URL(string: "https://example.com/c.png")!),
    ]

    @Test func refreshCachesAndSearchFilters() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = PresetCatalog(cacheFolder: folder)
        await catalog.loadCache()
        #expect(catalog.presets.isEmpty)
        let presets = Self.presets
        await catalog.refresh { presets }
        #expect(catalog.presets == Self.presets)
        catalog.query = "  clay "
        #expect(catalog.filtered.map(\.name) == ["Claymation"])
        #expect(catalog.preset(id: Self.presets[0].id)?.name == "Cel-Shaded CG Anime")

        let reopened = PresetCatalog(cacheFolder: folder)
        await reopened.loadCache()
        #expect(reopened.presets == Self.presets)
        await reopened.refresh { throw ProviderError.network }
        #expect(reopened.presets == Self.presets)
        #expect(reopened.refreshFailure?.title == "Can't reach Higgsfield")
        #expect(!reopened.isRefreshing)
        #expect(PresetCatalog.cachedName(of: Self.presets[0].id, in: folder) == "Cel-Shaded CG Anime")
        #expect(PresetCatalog.cachedName(of: UUID(), in: folder) == nil)
        #expect(PresetCatalog.cachedName(of: Self.presets[0].id, in: folder.appendingPathComponent("missing")) == nil)
    }

    @Test func cacheNeverReplacesPresetsAlreadyShown() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = Self.presets
        await PresetCatalog(cacheFolder: folder).refresh { cached }

        let catalog = PresetCatalog(cacheFolder: folder)
        let fresh = [Self.presets[1]]
        await catalog.refresh { fresh }
        await catalog.loadCache()

        #expect(catalog.presets == fresh)
    }

    @Test func unreadableCacheIsIgnored() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent(PresetCatalog.cacheFileName))

        let catalog = PresetCatalog(cacheFolder: folder)
        await catalog.loadCache()

        #expect(catalog.presets.isEmpty)
    }
}
