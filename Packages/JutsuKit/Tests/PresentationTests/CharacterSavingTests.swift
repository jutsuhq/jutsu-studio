import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Publishes an element unless `fails`, which refuses it like the server would.
private struct PublishingElements: AccountElements {
    var fails = false
    let created = Box<[String]>([])

    var owner: String? { "user_1" }

    func elements(after cursor: HistoryCursor?) async throws -> AccountElementPage {
        AccountElementPage(items: [], nextCursor: nil)
    }

    func elementImages(_ element: AccountElement) async throws -> AccountElement { element }

    func createElement(name: String, category: ElementCategory, images: [RemoteAsset]) async throws -> AccountElement {
        if fails { throw ProviderError.server(status: 500) }
        created.update { $0.append("\(name) \(images.compactMap(\.id))") }
        return AccountElement(id: "el-new", name: name, category: category)
    }
}

@MainActor
@Suite struct CharacterSavingTests {
    static let images = [
        LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.png")),
        LocalImage(fileURL: URL(fileURLWithPath: "/tmp/b.png")),
    ]

    static let upload: @Sendable (LocalImage) async throws -> RemoteAsset = { image in
        RemoteAsset(url: URL(string: "https://cdn.example.com/x")!, id: image.fileURL.lastPathComponent)
    }

    @Test func thereIsNoSaveWithoutElementsThatPublishOrAnUpload() {
        let offered = AccountElementsModel(source: PublishingElements(), isOffered: true)
        let unconfirmed = AccountElementsModel(source: PublishingElements(), isOffered: false)

        #expect(CharacterSaving(elements: nil, owner: "user_1", upload: Self.upload) { _, _ in } == nil)
        #expect(CharacterSaving(elements: unconfirmed, owner: "user_1", upload: Self.upload) { _, _ in } == nil)
        #expect(CharacterSaving(elements: offered, owner: "user_1", upload: nil) { _, _ in } == nil)
    }

    @Test func aSavedSetIsRecordedForItsImages() async throws {
        let source = PublishingElements()
        var recorded: [(SavedElement, [LocalImage])] = []
        let saving = try #require(
            CharacterSaving(
                elements: AccountElementsModel(source: source, isOffered: true), owner: "user_1", upload: Self.upload
            ) { recorded.append(($0, $1)) })

        let failure = await saving.save(Self.images, "  Mara  ")

        #expect(failure == nil)
        #expect(saving.owner == "user_1")
        #expect(source.created.value == ["Mara [\"a.png\", \"b.png\"]"])
        #expect(recorded.map(\.0) == [SavedElement(id: "el-new", owner: "user_1")])
        #expect(recorded.map(\.1) == [Self.images])
    }

    @Test func aRefusedSaveRecordsNothingAndSaysSo() async throws {
        var recorded = 0
        let saving = try #require(
            CharacterSaving(
                elements: AccountElementsModel(source: PublishingElements(fails: true), isOffered: true),
                owner: "user_1", upload: Self.upload
            ) { _, _ in recorded += 1 })

        let failure = await saving.save(Self.images, "Mara")

        #expect(failure?.title == SavedElement.failureTitle)
        #expect(recorded == 0)
    }
}
