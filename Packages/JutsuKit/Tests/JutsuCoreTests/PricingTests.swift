import Foundation
import Testing

@testable import JutsuCore

@Test(arguments: [
    (8.1, 9), (12.0, 12), (12.000_000_1, 12), (11.999_999_9, 12), (4.0, 4), (29.5, 30), (0, 0),
])
func billedSecondsRoundUp(duration: TimeInterval, expected: Int) {
    #expect(Pricing.billedSeconds(duration) == expected)
}

@Test func bundledRatesAreExactDecimals() throws {
    let pricing = try Pricing.bundled()
    for mode in Mode.allCases where VideoModel.genjutsu.serves(mode) {
        let rates = mode == .restyle ? ["0.318", "0.681", "1.632"] : ["0.154", "0.3446", "0.8346"]
        #expect(try pricing.rate(for: makeSpec(mode: mode, resolution: .p480)) == Decimal(string: rates[0]))
        #expect(try pricing.rate(for: makeSpec(mode: mode, resolution: .p720)) == Decimal(string: rates[1]))
        #expect(try pricing.rate(for: makeSpec(mode: mode, resolution: .p1080)) == Decimal(string: rates[2]))
    }
}

/// Genjutsu Lite's list prices per second, -e.05, -e.10 and -e.20, bill the output and the input video alike, so a
/// job on a source pays twice the rate per second of its selection. Object Swap's are kept, though no job uses them.
@Test func genjutsuLiteHasItsListPrices() throws {
    let pricing = try Pricing.bundled()
    let rates = [Resolution.p480: "0.0739", .p720: "0.1471", .p1080: "0.2936"].compactMapValues { Decimal(string: $0) }
    #expect(pricing.rates["higgsfield/genjutsu-light/motion-transfer/v1.0"] == rates)
    #expect(pricing.rates["higgsfield/genjutsu-light/object-swap/v1.0"] == rates)
    let lite = try #require(VideoModel(rawValue: "genjutsuLite"))
    for (resolution, rate) in rates {
        var spec = makeSpec(mode: .motionTransfer, resolution: resolution)
        spec.model = lite
        #expect(try pricing.rate(for: spec) == rate)
    }
}

/// Seedance's list price is per second of output, with a higher rate when a source clip goes with the job; the
/// clip's own seconds aren't added. Kling's quality is its endpoint: Standard below 1080p, Pro at 1080p.
@Test(arguments: [
    (VideoModel.seedance25, false, false, Resolution.p720, "0.2647"),
    (.seedance25, false, true, .p480, "0.1177"),
    (.seedance25, true, true, .p1080, "0.7858"),
    (.klingMotionControl, true, true, .p480, "0.092"),
    (.klingMotionControl, true, true, .p720, "0.092"),
    (.klingMotionControl, true, true, .p1080, "0.1189"),
])
func otherModelsArePricedByTheirEndpoint(
    model: VideoModel, hasSource: Bool, hasReferences: Bool, resolution: Resolution, rate: String
) throws {
    let pricing = try Pricing.bundled()
    #expect(
        try pricing.rate(
            model: model, mode: .motionTransfer, resolution: resolution, hasSource: hasSource,
            hasReferences: hasReferences) == Decimal(string: rate))
}

@Test func otherModelsGiveAnEstimate() throws {
    var spec = makeSpec(duration: 10, resolution: .p720)
    spec.model = .klingMotionControl

    #expect(try Pricing.bundled().cost(for: spec) == .usd(Decimal(string: "0.92")!, isEstimate: true))
}

@Test func costIsBilledSecondsTimesRate() throws {
    let pricing = try Pricing.bundled()
    #expect(
        try pricing.cost(for: makeSpec(duration: 12, resolution: .p480))
            == .usd(Decimal(string: "1.848")!, isEstimate: false))
    #expect(
        try pricing.cost(for: makeSpec(duration: 8.1, resolution: .p720))
            == .usd(Decimal(string: "3.1014")!, isEstimate: false))
    #expect(
        try pricing.cost(for: makeSpec(mode: .objectSwap, duration: 30, resolution: .p1080))
            == .usd(Decimal(string: "25.038")!, isEstimate: false))
}

/// open.higgsfield.ai: Edit and Extend take the with-video rate per second of output. Edit's output is as long as its
/// source selection; Extend bills only the part it adds, not the existing video.
@Test func editIsBilledOnTheSourceAndExtendOnlyOnTheAddedPart() throws {
    let pricing = try Pricing.bundled()
    var edit = makeSpec(mode: .edit, duration: 8, resolution: .p720)
    edit.model = .seedance25
    var extend = makeSpec(mode: .extend, duration: 8, resolution: .p720)
    extend.model = .seedance25
    extend.length = 5

    #expect(Pricing.billedSeconds(for: edit) == 8)
    #expect(Pricing.billedSeconds(for: extend) == 5)
    #expect(Pricing.billedSeconds(for: extend, on: .apiKey) == 5)
    #expect(try pricing.cost(for: edit) == .usd(Decimal(string: "2.6112")!, isEstimate: true))
    #expect(try pricing.cost(for: extend) == .usd(Decimal(string: "1.632")!, isEstimate: true))
    #expect(try pricing.rate(for: extend) == Decimal(string: "0.3264"))
}

@Test func missingRateIsRejectedAtLoad() {
    let json = #"{"models": {"higgsfield/genjutsu/motion-transfer/v1.0": {"480p": 0.318}}}"#
    #expect(throws: Pricing.LoadError.missingRate("higgsfield/genjutsu/motion-transfer/v1.0", .p720)) {
        try Pricing(data: Data(json.utf8))
    }
}

/// Each tariff is priced above $0, or listed as unpriced (`null`) where no page states its rate.
@Test func bundledPricingCoversEveryTariffAndResolution() throws {
    let pricing = try Pricing.bundled()
    for (tariff, resolution) in Pricing.tariffs {
        if pricing.unpriced.contains(Pricing.TariffKey(tariff, resolution)) { continue }
        #expect(try #require(pricing.rates[tariff]?[resolution]) > 0, "\(tariff) \(resolution)")
    }
}

/// A `null` rate loads as unpriced: the job's list price is `Cost.unknownUSD`, never $0, and the rate throws. No
/// bundled tariff is unpriced any more, so Kling O3 Edit at 1080p is taken out of the bundled rates here.
@Test func anUnpricedRateIsUnknownNotFree() throws {
    let unpriced = Pricing.TariffKey("kling-video/o3/video-edit", .p1080)
    let bundled = try Pricing.bundled()
    var rates = bundled.rates
    rates[unpriced.tariff]?[unpriced.resolution] = nil
    let pricing = try Pricing(rates: rates, unpriced: [unpriced], upperBounds: bundled.upperBounds)
    let edit = try #require(VideoModel(rawValue: "klingO3VideoEdit"))
    let spec = JobSpec(
        mode: .edit, model: edit,
        source: SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 30,
            pixelSize: PixelSize(width: 1280, height: 720), range: 0...5),
        prompt: "dance", resolution: .p1080)
    #expect(try pricing.cost(for: spec) == .unknownUSD)
    #expect(throws: Pricing.LoadError.unpricedRate("kling-video/o3/video-edit", .p1080)) {
        try pricing.rate(for: spec)
    }
    let json = #"{"models": {"higgsfield/genjutsu/motion-transfer/v1.0": {"480p": null}}}"#
    #expect(throws: Pricing.LoadError.missingRate("higgsfield/genjutsu/motion-transfer/v1.0", .p720)) {
        try Pricing(data: Data(json.utf8))
    }
}

/// A model's tariffs need only the resolutions it renders at: Wan 2.7 has no 480p, Cinema Studio no 1080p.
@Test func tariffsFollowEachModelsResolutions() throws {
    let tariffs = Pricing.tariffs
    #expect(!tariffs.contains { $0.0 == "wan/v2.7/reference-to-video" && $0.1 == .p480 })
    #expect(tariffs.contains { $0.0 == "wan/v2.7/reference-to-video" && $0.1 == .p720 })
    #expect(!tariffs.contains { $0.0 == "higgsfield/cinema-studio/4.0" && $0.1 == .p1080 })
    #expect(tariffs.contains { $0.0 == "higgsfield/genjutsu/motion-transfer/v1.0" && $0.1 == .p480 })
}

/// The list prices of the models added for issue #101, at the 2026-11-14 rates.
@Test(arguments: [
    ("klingMotionControl26", Resolution.p720, "0.0523"), ("klingMotionControl26", .p1080, "0.0779"),
    ("klingO3VideoEdit", .p720, "0.0945"), ("wan27Reference", .p720, "0.075"), ("wan27Reference", .p1080, "0.1125"),
])
func listPricesOfTheNewModels(id: String, resolution: Resolution, rate: String) throws {
    let model = try #require(VideoModel(rawValue: id))
    let mode = try #require(model.modes.first)
    let found = try Pricing.bundled().rate(
        model: model, mode: mode, resolution: resolution, hasSource: true, hasReferences: false)
    #expect(found == Decimal(string: rate))
}

/// Issue #113's models at the rates open.higgsfield.ai publishes on 2026-11-14, with a source clip: Wan 3.0, Wan 3.0
/// Prime and Cinema Studio 4.0 take their "with video reference" rate. Kling O3 and Kling O3 Edit state no 480p rate,
/// so 480p takes the 720p one as its top and is marked as an upper bound.
@Test(arguments: [
    ("wan30Reference", Mode.motionTransfer, Resolution.p480, "0.0747", false),
    ("wan30Reference", .motionTransfer, .p720, "0.1493", false),
    ("wan30Reference", .motionTransfer, .p1080, "0.3011", false),
    ("wan30PrimeReference", .motionTransfer, .p480, "0.1013", false),
    ("wan30PrimeReference", .motionTransfer, .p720, "0.2084", false),
    ("wan30PrimeReference", .motionTransfer, .p1080, "0.4341", false),
    ("cinemaStudio4", .motionTransfer, .p480, "0.2468", false),
    ("cinemaStudio4", .motionTransfer, .p720, "0.5547", false),
    ("klingO3VideoReference", .motionTransfer, .p480, "0.0945", true),
    ("klingO3VideoReference", .motionTransfer, .p720, "0.0945", false),
    ("klingO3VideoReference", .motionTransfer, .p1080, "0.1263", false),
    ("klingO3VideoEdit", .edit, .p480, "0.0945", true),
    ("klingO3VideoEdit", .edit, .p720, "0.0945", false),
])
func publishedRatesOfIssue113(id: String, mode: Mode, resolution: Resolution, rate: String, isUpTo: Bool) throws {
    let model = try #require(VideoModel(rawValue: id))
    let pricing = try Pricing.bundled()
    let found = try pricing.rate(model: model, mode: mode, resolution: resolution, hasSource: true, hasReferences: true)
    #expect(found == Decimal(string: rate))
    #expect(
        pricing.isUpperBound(model: model, mode: mode, resolution: resolution, hasSource: true, hasReferences: true)
            == isUpTo)
}

/// Wan 3.0, Wan 3.0 Prime and Cinema Studio 4.0 bill a source clip at their "with video reference" tariff, and
/// without one at the plain endpoint.
@Test(arguments: [
    ("wan30Reference", "alibaba/wan-3.0/reference-to-video"),
    ("wan30PrimeReference", "alibaba/wan-3.0-prime/reference-to-video"),
    ("cinemaStudio4", "higgsfield/cinema-studio/4.0"),
])
func aSourceClipUsesTheWithVideoReferenceTariff(id: String, endpoint: String) throws {
    let model = try #require(VideoModel(rawValue: id))
    for hasSource in [true, false] {
        let tariff = Pricing.tariffID(
            model: model, mode: .motionTransfer, resolution: .p720, hasSource: hasSource, hasReferences: true)
        #expect(tariff == (hasSource ? endpoint + " with video reference" : endpoint))
    }
}

/// `{"upTo": rate}` loads as that rate, marked as the top of a range: always an estimate, even on a model whose list
/// price is otherwise exact.
@Test func anUpperBoundLoadsAsAnEstimate() throws {
    let url = try #require(JutsuCoreResources.pricingURL)
    var file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var models = try #require(file["models"] as? [String: Any])
    models["higgsfield/genjutsu/motion-transfer/v1.0"] = ["480p": ["upTo": 0.5], "720p": 0.681, "1080p": 1.632]
    file["models"] = models
    let pricing = try Pricing(data: JSONSerialization.data(withJSONObject: file))

    let spec = makeSpec(duration: 10, resolution: .p480)
    #expect(pricing.isUpperBound(for: spec))
    #expect(try pricing.rate(for: spec) == Decimal(string: "0.5"))
    #expect(try pricing.cost(for: spec) == .usd(5, isEstimate: true))
    let exact = makeSpec(duration: 10, resolution: .p720)
    #expect(!pricing.isUpperBound(for: exact))
    #expect(try pricing.cost(for: exact) == .usd(Decimal(string: "6.81") ?? 0, isEstimate: false))
}

@Test(arguments: [(TimeInterval.nan, 0), (-5, 0), (.infinity, Int.max), (1e300, Int.max)])
func billedSecondsClampsInsteadOfTrapping(duration: TimeInterval, expected: Int) {
    #expect(Pricing.billedSeconds(duration) == expected)
}

/// open.higgsfield.ai prices `image-to-video` like a clip without video input: images aren't billed as video.
@Test func framesArePricedAsAClipWithoutVideoInput() throws {
    let pricing = try Pricing.bundled()
    let frames = [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/start.png"))]
    let spec = JobSpec(
        mode: .motionTransfer, model: .seedance25, source: nil, references: frames, resolution: .p1080, length: 8,
        referencesAreFrames: true)
    let tariff = Pricing.tariffID(
        model: .seedance25, mode: .motionTransfer, resolution: .p1080, hasSource: false, hasReferences: true,
        usesFrames: true)
    #expect(tariff == "bytedance/seedance-2.5/image-to-video")
    #expect(try pricing.rate(for: spec) == Decimal(string: "0.6518"))
    #expect(try pricing.cost(for: spec) == .usd(Decimal(string: "5.2144") ?? 0, isEstimate: true))
}
