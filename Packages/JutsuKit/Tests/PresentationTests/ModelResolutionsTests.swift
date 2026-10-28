import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// The resolution picker follows the selected model's resolutions (`models.json`), and a job on a model with no
/// published rate shows "Price unknown" instead of a number.
@Suite struct ModelResolutionsTests {
    static let wan27 = VideoModel(rawValue: "wan27Reference")
    static let wan30 = VideoModel(rawValue: "wan30Reference")
    static let cinema = VideoModel(rawValue: "cinemaStudio4")
    static let klingO3Edit = VideoModel(rawValue: "klingO3VideoEdit")

    static let apiKey: CreateContext = {
        var context = CreateFixture.apiKey
        context.capabilities = Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases), resolutions: Set(Resolution.allCases),
            costUnit: .usd, maxConcurrency: nil)
        return context
    }()

    static func form(_ model: VideoModel?, resolution: Resolution) throws -> CreateForm {
        var form = CreateFixture.ready(resolution)
        form.model = try #require(model)
        form.prompt = "she spins"
        return form
    }

    /// Wan 2.7 offers 720p and 1080p; a form kept at 480p shows and makes 720p, and the form keeps its 480p for the
    /// models that have it.
    @Test func thePickerOffersTheModelsResolutions() throws {
        var form = try Self.form(Self.wan27, resolution: .p480)
        #expect(form.resolutionOptions == [.p720, .p1080])
        #expect(form.pickedResolution == .p720)
        #expect(form.makeSpecs(isDraft: false).map(\.resolution) == [.p720])
        #expect(form.resolution == .p480)

        form.pickedResolution = .p1080
        #expect(form.makeSpecs(isDraft: false).map(\.resolution) == [.p1080])
        form.model = .genjutsu
        #expect(form.resolutionOptions == Resolution.standard)
        #expect(form.pickedResolution == .p1080)
    }

    /// Cinema Studio stops at 720p, so 1080p comes down to it.
    @Test func aResolutionAboveTheModelsComesDown() throws {
        let form = try Self.form(Self.cinema, resolution: .p1080)
        #expect(form.resolutionOptions == [.p480, .p720])
        #expect(form.makeSpecs(isDraft: false).map(\.resolution) == [.p720])
    }

    /// The models that render at 480p, 720p and 1080p keep the form's exactly as before.
    @Test func theOtherModelsKeepEveryResolution() {
        let own = ["kling40", "wan27Reference", "cinemaStudio4", "minimaxH3Reference", "minimaxH3MaxReference"]
        for model in VideoModel.allCases where !own.contains(model.rawValue) {
            #expect(model.resolutions == Resolution.standard, "\(model.rawValue)")
            for resolution in Resolution.standard { #expect(model.fitted(resolution) == resolution) }
        }
    }

    /// Wan 2.7 is priced per resolution; the list price follows the resolution the job is made at.
    @Test func wan27IsPricedAtItsOwnResolution() throws {
        try CostText.$locale.withValue(.enUS) {
            let form = try Self.form(Self.wan27, resolution: .p480)
            #expect(form.rateText(in: Self.apiKey) == "$0.100 / s")
            #expect(form.blocker(isDraft: false, in: Self.apiKey) == nil)
        }
    }

    /// No page states Kling O3 Edit's Pro rate: the price reads as unknown, never as $0, and under a cap the submit
    /// asks first.
    @Test func anUnpricedModelSaysThePriceIsUnknown() throws {
        try CostText.$locale.withValue(.enUS) {
            let form = try Self.klingO3EditPro()
            let cost = Self.apiKey.cost(for: form.makeSpecs(isDraft: false))
            #expect(cost == .unknownUSD)
            #expect(form.rateText(in: Self.apiKey) == nil)
            #expect(form.priceText(isDraft: false, in: Self.apiKey) == PostOperationText.priceUnknown)
            let line = try #require(form.costLine(in: Self.apiKey))
            #expect(line.text == "15 s · Price unknown")
            #expect(line.detail == "Higgsfield quotes it once the files are uploaded · failed runs are free")

            var capped = Self.apiKey
            capped.cap = SpendCap(amount: 50, unit: .usd)
            guard case .confirm(_, let confirmation) = form.submitDecision(isDraft: false, in: capped) else {
                Issue.record("expected a confirmation")
                return
            }
            #expect(confirmation.title == "Price not known yet")
            #expect(form.submitDecision(isDraft: false, in: Self.apiKey) == .start(form.makeSpecs(isDraft: false)))
        }
    }

    /// One unknown price makes the whole sum unknown rather than the sum of the known part.
    @Test func aSumWithAnUnknownPartIsUnknown() throws {
        var known = try Self.form(Self.wan27, resolution: .p720).makeSpecs(isDraft: false)
        let unknown = try Self.klingO3EditPro().makeSpecs(isDraft: false)
        known += unknown
        #expect(Self.apiKey.cost(for: known) == .unknownUSD)
    }

    static func klingO3EditPro() throws -> CreateForm {
        var form = try Self.form(Self.klingO3Edit, resolution: .p1080)
        form.mode = .edit
        return form
    }

    /// Wan 3.0's list price per second at each resolution (open.higgsfield.ai/pricing, 2026-10-15, before discounts).
    @Test func wan30HasItsPublishedRate() throws {
        try CostText.$locale.withValue(.enUS) {
            let form = try Self.form(Self.wan30, resolution: .p720)
            #expect(form.rateText(in: Self.apiKey) == "$0.100 / s")
            let line = try #require(form.costLine(in: Self.apiKey))
            #expect(line.text == "15 s = $1.50")
            #expect(line.detail == "Estimate · failed runs are free")
        }
    }

    /// MiniMax H3 renders at 2K only, at $0.13 a generated second (open.higgsfield.ai/pricing, 2026-10-15, before
    /// the 50% discount), whatever the form's resolution.
    @Test func miniMaxH3IsPricedAt2K() throws {
        try CostText.$locale.withValue(.enUS) {
            let form = try Self.form(VideoModel(rawValue: "minimaxH3Reference"), resolution: .p480)
            #expect(form.resolutionOptions == [.k2] && form.pickedResolution == .k2)
            #expect(form.makeSpecs(isDraft: false).map(\.resolution) == [.k2])
            #expect(form.rateText(in: Self.apiKey) == "$0.130 / s")
            let line = try #require(form.costLine(in: Self.apiKey))
            #expect(line.text == "15 s = $1.95")
            #expect(line.detail == "Estimate · failed runs are free")
        }
    }

    /// Cinema Studio publishes only a range over all its settings: the price is its top, said as "up to", until
    /// Higgsfield quotes the uploaded files.
    @Test func aRangeIsShownAsUpToItsTop() throws {
        try CostText.$locale.withValue(.enUS) {
            let form = try Self.form(Self.cinema, resolution: .p480)
            let cost = Self.apiKey.cost(for: form.makeSpecs(isDraft: false))
            #expect(cost == .usd(Decimal(string: "6.9345") ?? 0, isEstimate: true))
            // Rounded up, so an "up to" price never reads lower than the rate.
            #expect(form.rateText(in: Self.apiKey) == "up to $0.463 / s")
            let line = try #require(form.costLine(in: Self.apiKey))
            #expect(line.text == "15 s = up to $6.94")
            #expect(line.detail == "Top of Higgsfield's published range, quoted after upload · failed runs are free")
        }
    }
}
