import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct PresetShelfTests {
    private static func preset(_ name: String, _ index: UInt8) -> StylePreset {
        let id = UUID(uuid: (index, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let url = URL(string: "https://example.com/\(index).webp") ?? URL(fileURLWithPath: "/")
        return StylePreset(id: id, name: name, previewURL: url)
    }

    private let clay = Self.preset("Claymation", 1)
    private let anime = Self.preset("Cel-Shaded CG Anime", 2)
    private let noir = Self.preset("Film Noir", 3)
    private let pixel = Self.preset("Pixel Art", 4)

    private func sections(
        catalog: [StylePreset], favorites: [StylePreset] = [], recents: [StylePreset] = [],
        selection: UUID? = nil, query: String = ""
    ) -> [PresetGallerySection] {
        PresetShelf.sections(
            catalog: catalog, favorites: favorites, recents: recents, selection: selection, query: query)
    }

    private func names(_ sections: [PresetGallerySection]) -> [PresetGallerySection.Kind: [String]] {
        Dictionary(uniqueKeysWithValues: sections.map { ($0.kind, $0.items.map(\.name)) })
    }

    @Test func favoritesThenRecentThenWholeCatalog() {
        let result = sections(catalog: [clay, anime, noir], favorites: [noir], recents: [anime, noir])
        #expect(result.map(\.kind) == [.favorites, .recent, .all])
        #expect(names(result)[.favorites] == ["Film Noir"])
        #expect(names(result)[.recent] == ["Cel-Shaded CG Anime", "Film Noir"])
        #expect(names(result)[.all] == ["Claymation", "Cel-Shaded CG Anime", "Film Noir"])
        #expect(result.last?.items.map(\.isFavorite) == [false, false, true])
        #expect(result.allSatisfy { $0.items.allSatisfy(\.isAvailable) })
    }

    @Test func emptySectionsAreLeftOut() {
        #expect(sections(catalog: [clay]).map(\.kind) == [.all])
        #expect(sections(catalog: []).isEmpty)
    }

    @Test func sectionsAreDeduplicatedAndRecentIsCapped() {
        let more = (10..<20).map { Self.preset("Style \($0)", UInt8($0)) }
        let result = sections(catalog: [clay] + [clay] + more, favorites: [clay, clay], recents: [clay] + more)
        #expect(names(result)[.favorites] == ["Claymation"])
        #expect(names(result)[.recent]?.count == PresetShelf.recentLimit)
        #expect(names(result)[.recent]?.first == "Claymation")
        #expect(names(result)[.all]?.filter { $0 == "Claymation" }.count == 1)
    }

    @Test func catalogVersionWinsOverTheStoredSnapshot() {
        var renamed = clay
        renamed.name = "Claymation v2"
        let result = sections(catalog: [renamed], favorites: [clay], recents: [clay])
        #expect(names(result)[.favorites] == ["Claymation v2"])
        #expect(names(result)[.recent] == ["Claymation v2"])
    }

    @Test func presetsMissingFromTheCatalogAreUnavailable() {
        let result = sections(catalog: [clay], favorites: [noir], recents: [anime])
        #expect(names(result)[.favorites] == ["Film Noir"])
        #expect(names(result)[.recent] == ["Cel-Shaded CG Anime"])
        #expect(result.first { $0.kind == .favorites }?.items.first?.isAvailable == false)
        #expect(result.first { $0.kind == .recent }?.items.first?.isAvailable == false)
        #expect(result.first { $0.kind == .all }?.items.first?.isAvailable == true)
    }

    @Test func aMissingSelectionShownNowhereElseGetsItsOwnSection() {
        let unknown = UUID()
        let result = sections(catalog: [clay], selection: unknown)
        #expect(result.map(\.kind) == [.selected, .all])
        #expect(
            result.first?.items == [
                PresetTileItem(
                    id: unknown, name: PresetShelf.unknownPresetName, previewURL: nil, isFavorite: false,
                    isAvailable: false)
            ])
    }

    @Test func aSelectionShownElsewhereGetsNoExtraSection() {
        #expect(sections(catalog: [clay], selection: clay.id).map(\.kind) == [.all])
        #expect(sections(catalog: [clay], favorites: [noir], selection: noir.id).map(\.kind) == [.favorites, .all])
        #expect(sections(catalog: [], recents: [anime], selection: anime.id).map(\.kind) == [.recent])
    }

    @Test func searchFiltersEverySectionIgnoringCaseAndAccents() {
        let result = sections(
            catalog: [clay, anime, noir], favorites: [noir, clay], recents: [anime, clay], query: "  CLÁY ")
        #expect(result.map(\.kind) == [.favorites, .recent, .all])
        #expect(result.allSatisfy { $0.items.map(\.name) == ["Claymation"] })
        #expect(sections(catalog: [clay], favorites: [clay], query: "pixel").isEmpty)
    }

    @Test func togglingStarsNewestFirstAndUnstarsMissingPresets() {
        var favorites = PresetShelf.toggledFavorite(clay.id, favorites: [], catalog: [clay, anime])
        favorites = PresetShelf.toggledFavorite(anime.id, favorites: favorites, catalog: [clay, anime])
        #expect(favorites == [anime, clay])
        #expect(PresetShelf.toggledFavorite(clay.id, favorites: favorites, catalog: []) == [anime])
        #expect(PresetShelf.toggledFavorite(noir.id, favorites: favorites, catalog: [clay]) == favorites)
    }

    @Test func recordingUseMovesThePresetToTheFrontAndCaps() {
        var recents: [StylePreset] = []
        for preset in [clay, anime, noir, clay] {
            recents = PresetShelf.recordingUse(
                preset.id, recents: recents, catalog: [clay, anime, noir], favorites: [])
        }
        #expect(recents == [clay, noir, anime])

        let more = (10..<20).map { Self.preset("Style \($0)", UInt8($0)) }
        for preset in more {
            recents = PresetShelf.recordingUse(preset.id, recents: recents, catalog: more, favorites: [])
        }
        #expect(recents == Array(more.reversed().prefix(PresetShelf.recentLimit)))
    }

    @Test func recordingUseFallsBackToStoredSnapshots() {
        #expect(PresetShelf.recordingUse(noir.id, recents: [clay], catalog: [], favorites: [noir]) == [noir, clay])
        #expect(
            PresetShelf.recordingUse(clay.id, recents: [anime, clay], catalog: [], favorites: []) == [clay, anime])
        #expect(PresetShelf.recordingUse(pixel.id, recents: [clay], catalog: [], favorites: []) == [clay])
    }

    @Test func storedListsRoundTripAndBadDataIsEmpty() {
        #expect(PresetShelf.decode(PresetShelf.encode([clay, anime])) == [clay, anime])
        #expect(PresetShelf.decode(nil).isEmpty)
        #expect(PresetShelf.decode(Data()).isEmpty)
        #expect(PresetShelf.decode(Data("not json".utf8)).isEmpty)
    }
}
