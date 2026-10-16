import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// One page: two elements of different categories, the first without images.
private struct FakeElements: AccountElements {
    let requests = Box<[String]>([])

    static let image = ElementImage(url: URL(string: "https://cdn.example.com/1.jpg")!)

    var owner: String? { "user_1" }

    func elements(after cursor: HistoryCursor?) async throws -> AccountElementPage {
        requests.update { $0.append("list elements") }
        let items = [
            AccountElement(id: "el-1", name: "Mara", category: .character),
            AccountElement(id: "el-2", name: "Roof", category: .environment, images: [Self.image]),
        ]
        return AccountElementPage(items: items, nextCursor: nil)
    }

    func elementImages(_ element: AccountElement) async throws -> AccountElement {
        requests.update { $0.append("get \(element.id)") }
        var full = element
        full.images = [Self.image, Self.image]
        return full
    }

    func createElement(name: String, category: ElementCategory, images: [RemoteAsset]) async throws -> AccountElement {
        requests.update { $0.append("create \(name) \(category.rawValue) \(images.compactMap(\.id))") }
        return AccountElement(id: "el-new", name: name, category: category)
    }
}

@MainActor
@Suite struct AccountElementsModelTests {
    static func images(_ count: Int) -> [ElementImage] {
        (0..<count).map { ElementImage(url: URL(string: "https://cdn.example.com/\($0).jpg")!) }
    }

    @Test func unconfirmedElementsAreNeverFetched() async throws {
        let source = FakeElements()
        let model = AccountElementsModel(source: source, isOffered: false)

        await model.loadIfNeeded()
        _ = try await model.withImages(AccountElement(id: "el-1", name: "Mara"))

        #expect(model.unavailableReason == PostOperationText.waitingForCatalog)
        #expect(model.current.isEmpty)
        #expect(source.requests.value.isEmpty)
    }

    @Test func theCategoryFiltersTheLoadedList() async {
        let source = FakeElements()
        let model = AccountElementsModel(source: source, isOffered: true)
        await model.loadIfNeeded()

        #expect(model.unavailableReason == nil)
        #expect(model.current.map(\.id) == ["el-1", "el-2"])
        model.category = .environment
        #expect(model.current.map(\.id) == ["el-2"])
        #expect(source.requests.value == ["list elements"])
    }

    @Test func imagesAreAskedForOnlyWhenTheListNamedNone() async throws {
        let source = FakeElements()
        let model = AccountElementsModel(source: source, isOffered: true)
        await model.loadIfNeeded()

        let bare = try await model.withImages(model.current[0])
        let listed = try await model.withImages(model.current[1])

        #expect(bare.images.count == 2)
        #expect(listed.images.count == 1)
        #expect(source.requests.value == ["list elements", "get el-1"])
    }

    @Test func publishingUploadsEachImageThenCreatesACharacterOfferedFirst() async throws {
        let source = FakeElements()
        let model = AccountElementsModel(source: source, isOffered: true)
        await model.loadIfNeeded()
        let images = [1, 2].map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/\($0).png")) }
        let uploaded = Box<[URL]>([])

        let saved = try await model.publish(images, name: "  Mara  ") { image in
            uploaded.update { $0.append(image.fileURL) }
            return RemoteAsset(
                url: URL(string: "https://upload.example/\(image.fileURL.lastPathComponent)")!,
                id: "m-\(uploaded.value.count)")
        }

        #expect(saved == SavedElement(id: "el-new", owner: "user_1"))
        #expect(uploaded.value == images.map(\.fileURL))
        #expect(source.requests.value == ["list elements", "create Mara character [\"m-1\", \"m-2\"]"])
        #expect(model.current.map(\.id) == ["el-new", "el-1", "el-2"])
    }

    @Test func nothingIsUploadedOrPublishedWhileElementsArentOffered() async {
        let source = FakeElements()
        let model = AccountElementsModel(source: source, isOffered: false)
        let uploaded = Box(0)

        #expect(!model.canPublish)
        await #expect(throws: ProviderError.self) {
            try await model.publish([LocalImage(fileURL: URL(fileURLWithPath: "/tmp/1.png"))], name: "Mara") { _ in
                uploaded.update { $0 += 1 }
                return RemoteAsset(url: URL(string: "https://upload.example/1.png")!, id: "m-1")
            }
        }
        #expect(uploaded.value == 0)
        #expect(source.requests.value.isEmpty)
    }

    @Test func aFailedSaveSpeaksInPlainWords() {
        let refused = SavedElement.failure(ProviderError.validation(field: nil, message: "Image failed moderation"))
        #expect(refused == UserMessage(title: "Can't save to Higgsfield", message: "Image failed moderation"))
        #expect(SavedElement.failure(ProviderError.unauthorized)?.action == .openSettings)
        #expect(SavedElement.failure(CancellationError()) == nil)
        #expect(SavedElement.name("  " + String(repeating: "a", count: 40)) == String(repeating: "a", count: 32))
    }

    @Test func pickingAddsWhatFitsAndAsksWhenOverTheLimit() {
        func element(_ count: Int) -> AccountElement {
            AccountElement(id: "el", name: "Mara", images: Self.images(count))
        }

        #expect(ElementPick.of(element(3), limit: 3) == .add(Self.images(3)))
        #expect(ElementPick.of(element(5), limit: 2) == .choose(Self.images(5), limit: 2))
        #expect(ElementPick.of(element(0), limit: 2) == .unavailable("This element has no images to use."))
        #expect(ElementPick.of(element(1), limit: 0) == .unavailable("References are full."))
    }
}
