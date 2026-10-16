import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// The Enhance menu on a result's page (issue #41): when it shows, what an operation's job is, and how a price
/// that no quote exists for reads.
@Suite struct PostOperationsTests {
    static let accountResult: LibraryItemModel = {
        var item = LibraryFixture.item(via: .account)
        item.job.owner = "user_1"
        return item
    }()

    @Test func theMenuWaitsForTheCatalogOnTheAccount() {
        #expect(
            EnhanceAvailability.of(Self.accountResult, connection: .account, offered: false)
                == .disabled(reason: PostOperationText.waitingForCatalog))
        #expect(EnhanceAvailability.of(Self.accountResult, connection: .account, offered: true) == .available)
        // A result made with a key runs too, from an upload.
        #expect(EnhanceAvailability.of(LibraryFixture.item(), connection: .account, offered: true) == .available)
    }

    @Test func anAPIKeyHidesItOrSaysItNeedsTheAccount() {
        #expect(EnhanceAvailability.of(LibraryFixture.item(), connection: .apiKey, offered: true) == .hidden)
        #expect(
            EnhanceAvailability.of(Self.accountResult, connection: .apiKey, offered: true)
                == .disabled(reason: PostOperationText.needsAccount))
    }

    @Test func withoutADownloadedResultOrAConnectionThereIsNoMenu() {
        var remote = Self.accountResult
        remote.job.outputFile = URL(string: "https://cdn.example/out.mp4")
        #expect(EnhanceAvailability.of(remote, connection: .account, offered: true) == .hidden)
        #expect(EnhanceAvailability.of(Self.accountResult, connection: nil, offered: true) == .hidden)
    }

    @Test func theSignedInAccountsResultIsNamedByItsJobID() throws {
        let job = Self.accountResult.job
        let spec = try #require(
            job.operationSpec(
                .removeBackground, owner: "user_1", duration: 6.4, pixelSize: PixelSize(width: 3, height: 2)))

        #expect(spec.operation == PostOperation(action: .removeBackground, sourceJobID: "req-123"))
        #expect(spec.source?.fileURL == job.outputFile)
        #expect(spec.source?.range == 0...6.4)
        #expect(spec.source?.pixelSize == PixelSize(width: 3, height: 2))
        #expect(spec.references.isEmpty)
        #expect(spec.prompt.isEmpty)
        #expect(spec.isDraft == false)
    }

    @Test func anotherAccountsOrAKeysResultIsUploaded() throws {
        let other = try #require(Self.accountResult.job.operationSpec(.removeBackground, owner: "user_2"))
        let key = try #require(LibraryFixture.item().job.operationSpec(.removeBackground, owner: nil))
        #expect(other.operation?.sourceJobID == nil)
        #expect(key.operation?.sourceJobID == nil)
    }

    @Test func anUnknownPriceIsNeverShownAsANumber() {
        var job = Self.accountResult.job
        job.spec = job.operationSpec(.upscale(UpscaleOptions(target: .k4)), owner: "user_1") ?? job.spec
        job.cost = .unknownCredits
        job.state = .processing

        #expect(job.priceIsUnknown)
        #expect(JobRowModel(job, now: LibraryFixture.now).cost == PostOperationText.priceUnknown)
        #expect(JobRowModel(job, now: LibraryFixture.now).title == "out · Upscale to 4K")
        #expect(job.priceSource == PostOperationText.chargedOnCompletion)
        #expect(QueuedNotice([job])?.price == PostOperationText.priceUnknown)
        #expect(LibraryItemModel(job: job).billingSummary.hasPrefix(PostOperationText.priceUnknown))
        #expect(PostOperationText.price(.unknownCredits) == PostOperationText.unknownPriceNotice)

        job.serverPrice = .credits(14, isEstimate: false)
        #expect(!job.priceIsUnknown)
        #expect(PostOperationText.price(.credits(14, isEstimate: false)).hasPrefix("14 cr"))
    }

    /// A Topaz upscale has no quote (issue #113): the sheet says its price comes after the run, and once the charge
    /// is read from the credit history it shows as Higgsfield's price.
    @Test func aTopazUpscaleIsPricedAfterTheRun() {
        let topaz = PostAction.upscale(UpscaleOptions(target: .k4, engine: .topaz))
        #expect(topaz.isPricedAfterRun)
        #expect(!PostAction.upscale(UpscaleOptions(target: .k4)).isPricedAfterRun)
        #expect(!PostAction.removeBackground.isPricedAfterRun)
        #expect(PostOperationText.price(.unknownCredits, for: topaz) == PostOperationText.priceAfterRunNotice)
        #expect(PostOperationText.priceAfterRunNotice.hasPrefix("Price shown after the run"))
        #expect(
            PostOperationText.price(.unknownCredits, for: .removeBackground) == PostOperationText.unknownPriceNotice)

        var job = Self.accountResult.job
        job.spec = job.operationSpec(topaz, owner: "user_1") ?? job.spec
        job.cost = .unknownCredits
        job.state = .processing
        #expect(QueuedNotice([job])?.price == PostOperationText.priceAfterRun)
        #expect(job.priceSource == PostOperationText.chargedOnCompletion)

        job.state = .done
        job.serverPrice = .credits(41, isEstimate: false)
        #expect(!job.priceIsUnknown)
        #expect(job.priceSource != PostOperationText.chargedOnCompletion)
        #expect(QueuedNotice([job])?.price == JobRowModel.format(.credits(41, isEstimate: false), charged: true))
    }

    /// A generation on a model whose rate no page or quote states is unknown too, until the server prices it.
    @Test func aGenerationWithoutARateIsUnknownUntilQuoted() {
        var job = Self.accountResult.job
        job.cost = .unknownCredits
        #expect(job.priceIsUnknown)
        job.cost = .unknownUSD
        #expect(job.priceIsUnknown)
        job.serverPrice = .usd(1.5, isEstimate: false)
        #expect(!job.priceIsUnknown)
        job.cost = .credits(1, isEstimate: true)
        job.serverPrice = nil
        #expect(!job.priceIsUnknown)
    }

    @Test func theNewOperationsNameThemselves() {
        let voice = VoiceChoice(id: "v-1", type: "element", name: "Amber")
        #expect(PostAction.reframe(.portrait).title == "Reframe to 9:16")
        #expect(PostAction.changeVoice(voice).title == "Change Voice to Amber")
        #expect(PostAction.reframe(.square).tag == "Reframe")
        #expect(PostAction.dub(.french).tag == "Dub")
        #expect(PostAction.changeVoice(voice).tag == "Voice")
        #expect(PostAction.reframe(.landscape).madeFrom("rooftop") == "Reframed from rooftop")
        #expect(PostAction.dub(.french).madeFrom("rooftop") == "Dubbed from rooftop")
        #expect(PostAction.changeVoice(voice).madeFrom("rooftop") == "Voice changed from rooftop")
        #expect(PostAction.Kind.changeVoice.title == "Change Voice")
    }

    @Test func languagesAreNamedAndSortedInTheUsersLanguage() {
        let english = Locale(identifier: "en_US")
        #expect(DubLanguage.allCases.count == 18)
        #expect(DubLanguage.french.title(locale: english) == "French")
        #expect(DubLanguage.chinese.title(locale: english) == "Chinese")
        #expect(DubLanguage.filipino.title(locale: english) == "Filipino")
        #expect(DubLanguage.french.title(locale: Locale(identifier: "de_DE")) == "Französisch")
        let sorted = DubLanguage.sorted(locale: english)
        #expect(sorted.first == .arabic)
        #expect(sorted.last == .turkish)
        #expect(Set(sorted) == Set(DubLanguage.allCases))
    }

    @Test func aVoiceSaysWhoseItIs() {
        #expect(AccountVoice(choice: VoiceChoice(id: "a", type: "element", name: "Mine")).kindLabel == "Yours")
        #expect(AccountVoice(choice: VoiceChoice(id: "b", type: "preset", name: "Amber")).kindLabel == "Built-in")
    }

    @Test func aTallerCanvasKeepsTheWidthAndFillsAboveAndBelow() throws {
        let canvas = try #require(ReframeCanvas(source: PixelSize(width: 1920, height: 1080), aspect: .portrait))
        #expect(canvas.widthOverHeight == 9.0 / 16)
        #expect(canvas.frameWidth == 1)
        #expect(abs(canvas.frameHeight - (9.0 / 16) / (16.0 / 9)) < 1e-9)
        #expect(canvas.frameX == 0)
        #expect(abs(canvas.frameY - (1 - canvas.frameHeight) / 2) < 1e-9)
        #expect(!canvas.isUnchanged)
    }

    @Test func aWiderCanvasKeepsTheHeightAndFillsTheSides() throws {
        let canvas = try #require(ReframeCanvas(source: PixelSize(width: 720, height: 1280), aspect: .square))
        #expect(canvas.frameHeight == 1)
        #expect(abs(canvas.frameWidth - 0.5625) < 1e-9)
        #expect(abs(canvas.frameX - 0.21875) < 1e-9)
        #expect(canvas.frameY == 0)
    }

    @Test func theSameShapeChangesNothingAndAnUnknownSizeHasNoCanvas() throws {
        #expect(try #require(ReframeCanvas(source: PixelSize(width: 1080, height: 1080), aspect: .square)).isUnchanged)
        #expect(ReframeCanvas(source: PixelSize(width: 0, height: 0), aspect: .square) == nil)
    }

    @Test func theUpscaleOptionsFollowTheEngine() {
        #expect(UpscaleEngine.topaz.targets == [.p1080, .k4])
        #expect(UpscaleEngine.standard.targets == UpscaleTarget.allCases)
        #expect(!UpscaleEngine.topaz.takesFrameRate)
        #expect(!UpscaleFrameRate.offered.contains(.keep))
        #expect(UpscaleOptions().frameRate == .fps24)
    }

    @Test func theResultSaysWhatItWasMadeFrom() {
        let upscaled = LibraryFixture.item()
        var item = upscaled
        item.job.spec.operation = PostOperation(action: .upscale(UpscaleOptions()))
        #expect(PostAction.removeBackground.madeFrom("rooftop") == "Background removed from rooftop")
        #expect(PostAction.upscale(UpscaleOptions()).madeFrom("rooftop") == "Upscaled from rooftop")
        #expect(item.modeTag == "Upscale")
        #expect(item.title == "rooftop · Upscale to 1080p")
    }
}
