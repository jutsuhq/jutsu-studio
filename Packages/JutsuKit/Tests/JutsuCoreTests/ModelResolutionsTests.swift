import Foundation
import Testing

@testable import JutsuCore

/// `models.json`'s per-model `resolutions`: decoded strictly, 480p, 720p and 1080p when left out, and a job asking
/// for another gets the nearest the model renders at.
@Suite struct ModelResolutionsCatalogTests {
    static func catalog(_ resolutions: String) throws -> VideoModelCatalog {
        let json = """
            {"models": [{"id": "m", "family": "M", "title": "M", "modes": ["motionTransfer"], \(resolutions)
            "request": {"shape": "genjutsu", "endpoints": {"default": "e"}}}]}
            """
        return try VideoModelCatalog(data: Data(json.utf8))
    }

    @Test func leftOutItIsEveryResolution() throws {
        #expect(try Self.catalog("")["m"]?.resolutions == Resolution.standard)
    }

    /// In `Resolution`'s order, whatever the file's.
    @Test func listedItIsThoseInOrder() throws {
        #expect(try Self.catalog(#""resolutions": ["1080p", "720p"],"#)["m"]?.resolutions == [.p720, .p1080])
    }

    /// An entry this version can't run as described is left out, like any other unreadable entry.
    @Test(arguments: [#""resolutions": [],"#, #""resolutions": ["4K"],"#, #""aspectRatios": ["5:4"],"#])
    func anUnknownOrEmptyListLeavesTheEntryOut(field: String) throws {
        let catalog = try Self.catalog(field)
        #expect(catalog["m"] == nil)
        #expect(catalog.entryCount == 1)
    }

    @Test func fittingPicksTheNearestAndTheHigherOnATie() throws {
        let wan27 = try #require(VideoModel(rawValue: "wan27Reference"))
        #expect(wan27.resolutions == [.p720, .p1080])
        #expect(wan27.fitted(.p480) == .p720)
        #expect(wan27.fitted(.p1080) == .p1080)
        let cinema = try #require(VideoModel(rawValue: "cinemaStudio4"))
        #expect(cinema.fitted(.p1080) == .p720)
        #expect(cinema.fitted(.p480) == .p480)
    }

    /// MiniMax's tiers: H3 renders at 2K only, H3 Max at 480p and 768p; the others take the nearest by frame height.
    @Test func miniMaxHasItsOwnTiers() throws {
        let h3 = try #require(VideoModel(rawValue: "minimaxH3Reference"))
        let max = try #require(VideoModel(rawValue: "minimaxH3MaxReference"))
        #expect(h3.resolutions == [.k2] && max.resolutions == [.p480, .p768])
        #expect(Resolution.standard.map(h3.fitted) == [.k2, .k2, .k2])
        #expect(Resolution.standard.map(max.fitted) == [.p480, .p768, .p768])
        #expect(VideoModel.genjutsu.fitted(.p768) == .p720 && VideoModel.genjutsu.fitted(.k2) == .p1080)
        #expect(Resolution.allCases.map(\.rawValue) == ["480p", "720p", "768p", "1080p", "2K"])
        #expect(Resolution.allCases.map(\.standardized) == [.p480, .p720, .p720, .p1080, .p1080])
        #expect(JobSpec(mode: .motionTransfer, model: h3, source: nil, resolution: .p720).resolution == .k2)
    }

    /// A spec is made at a resolution its model renders at.
    @Test func aSpecIsMadeAtOneOfTheModelsResolutions() throws {
        let wan27 = try #require(VideoModel(rawValue: "wan27Reference"))
        #expect(JobSpec(mode: .motionTransfer, model: wan27, source: nil, resolution: .p480).resolution == .p720)
        #expect(JobSpec(mode: .motionTransfer, source: nil, resolution: .p480).resolution == .p480)
    }
}
