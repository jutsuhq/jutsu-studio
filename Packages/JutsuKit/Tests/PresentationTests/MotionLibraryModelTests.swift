import Foundation
import JutsuCore
import Testing

@testable import Presentation

private struct FakeLibrary: MotionLibrary {
    var failing: Set<MotionShelf> = []

    func motionPresets(on shelf: MotionShelf, after cursor: HistoryCursor?) async throws -> MotionPresetPage {
        if failing.contains(shelf) { throw ProviderError.network }
        let items = (0..<2).map { index in
            MotionPreset(
                id: "\(shelf.rawValue)-0-\(index)", name: "Clip",
                videoURL: URL(string: "https://example.com/a.mp4")!)
        }
        return MotionPresetPage(items: items, nextCursor: nil)
    }
}

@MainActor
@Suite struct MotionLibraryModelTests {
    @Test func eachShelfKeepsItsOwnPages() async {
        let model = MotionLibraryModel(library: FakeLibrary())
        await model.loadIfNeeded()
        model.shelf = .trending
        #expect(model.current.isEmpty)
        await model.loadIfNeeded()
        #expect(model.current.first?.id == "trending-0-0")
        model.shelf = .featured
        #expect(model.current.count == 2)
    }

    @Test func aFailureStaysOnItsShelf() async {
        let model = MotionLibraryModel(library: FakeLibrary(failing: [.new]))
        model.shelf = .new
        await model.loadIfNeeded()
        #expect(model.failure != nil)
        #expect(model.hasMore)
        model.shelf = .featured
        await model.loadIfNeeded()
        #expect(model.failure == nil)
    }

}
