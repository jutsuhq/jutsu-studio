import Foundation
import JutsuCore
import Persistence
import SwiftData
import Testing

@Suite struct DeliverySetStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Delivery-\(UUID())")

    private func store() throws -> SwiftDataStore {
        try SwiftDataStore(modelContainer: StoreContainer.make(inMemory: true))
    }

    /// A saved image whose file holds `contents`.
    private func savedImage(
        _ store: SwiftDataStore, name: String, contents: String = "original"
    ) async throws
        -> Material
    {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(name).png")
        try Data(contents.utf8).write(to: file)
        let image = SavedImage(
            fileURL: file, prompt: "a lighthouse", model: "soul", aspectRatio: "1:1",
            createdAt: Date(timeIntervalSince1970: 1))
        return try await store.saveImage(
            image, remote: nil,
            generation: MaterialGeneration(prompt: "a lighthouse", model: "soul", parameters: Data("{}".utf8)),
            inputs: [], variantGroupID: nil)
    }

    private func exported(_ set: DeliverySet) -> DeliverySet {
        var set = set
        let tasks = DeliveryPlan.tasks(for: set, scope: .all) { _ in false }
        set.record(tasks.map { $0.result(.done) }, in: .init(url: folder), at: Date(timeIntervalSince1970: 100))
        return set
    }

    @Test func aSetExportedYesterdayStillHoldsItsVersionsAfterNewEdits() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try store()
        let material = try await savedImage(store, name: "hero")
        let set = exported(DeliverySet(name: "Client", items: DeliverySet.items(from: [material])))
        try await store.saveDeliverySet(set)
        let edit = folder.appending(path: "hero edited.png")
        try Data("edited".utf8).write(to: edit)

        let edited = try await store.addEditedVersion(of: material.reference, file: edit)
        let stored = try #require(try await store.deliverySets().first)

        #expect(edited.current.id != material.current.id)
        #expect(stored.items.map(\.reference) == [material.reference])
        #expect(stored.isFrozen)
        #expect(stored == set)
    }

    @Test func aFrozenSetRefusesOtherVersionsAndUnfreezing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try store()
        let first = try await savedImage(store, name: "one")
        let second = try await savedImage(store, name: "two")
        let set = exported(DeliverySet(name: "Client", items: DeliverySet.items(from: [first])))
        try await store.saveDeliverySet(set)

        var swapped = DeliverySet(id: set.id, name: set.name, items: DeliverySet.items(from: [second]))
        await #expect(throws: DeliverySetError.frozen) { try await store.saveDeliverySet(swapped) }
        swapped = DeliverySet(id: set.id, name: set.name, items: set.items)
        await #expect(throws: DeliverySetError.frozen) { try await store.saveDeliverySet(swapped) }

        var noted = set
        noted.note = "Approved by Anna"
        noted.reviewLink = "https://review.example/42"
        try await store.saveDeliverySet(noted)
        #expect(try await store.deliverySets() == [noted])
    }

    @Test func anUnexportedSetCanChangeItsVersions() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try store()
        let first = try await savedImage(store, name: "one")
        let second = try await savedImage(store, name: "two")
        var set = DeliverySet(name: "Draft", items: DeliverySet.items(from: [first]))
        try await store.saveDeliverySet(set)

        try set.setItems(DeliverySet.items(from: [first, second]))
        try await store.saveDeliverySet(set)

        #expect(try await store.deliverySets().first?.items.count == 2)
        try await store.deleteDeliverySet(id: set.id)
        #expect(try await store.deliverySets().isEmpty)
    }

    @Test func anEditBroughtBackBecomesANewVersionLinkedToItsSource() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try store()
        let material = try await savedImage(store, name: "hero")
        let source = material.reference
        let originalFile = try #require(material.current.fileURL)
        let edit = folder.appending(path: "hero edited.png")
        try Data("edited in Photoshop".utf8).write(to: edit)

        try await store.addEditedVersion(of: source, file: edit, at: Date(timeIntervalSince1970: 50))
        let stored = try #require(try await store.material(id: material.id))

        #expect(stored.versions.count == 2)
        #expect(stored.current.fileURL == edit)
        #expect(stored.current.inputs == [MaterialInput(source: source, role: .parent)])
        #expect(stored.current.generation?.prompt == "a lighthouse")
        #expect(stored.current.generation?.parameters == nil)
        #expect(stored.versions.first == material.current)
        #expect(try Data(contentsOf: originalFile) == Data("original".utf8))
        #expect(try await store.madeFrom(stored.reference) == [MaterialInput(source: source, role: .parent)])
        #expect(try await store.usedIn(source) == [stored.reference])
    }

    @Test func aVersionMadeOnThisMacCarriesItsOwnLengthAndSize() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try store()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var job = makeJob(state: .done)
        job.outputMedia = OutputMedia(duration: 5, pixelSize: PixelSize(width: 854, height: 480))
        let original = folder.appending(path: "rooftop.mp4")
        try Data("original".utf8).write(to: original)
        let material = try await store.saveMaterial(
            Material(id: job.id, kind: .video, version: MaterialVersion(fileURL: original, video: job)))
        let slow = folder.appending(path: "rooftop slow 2x.mp4")
        try Data("slow".utf8).write(to: slow)
        let media = OutputMedia(duration: 10, pixelSize: PixelSize(width: 854, height: 480))

        let stored = try await store.addEditedVersion(of: material.reference, file: slow, media: media)

        #expect(stored.current.video?.outputMedia == media)
        #expect(stored.current.video?.outputFile == slow)
        #expect(stored.current.pixelSize == media.pixelSize)
        #expect(stored.current.inputs == [MaterialInput(source: material.reference, role: .parent)])
        #expect(stored.versions.first?.video?.outputMedia?.duration == 5)
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func anEditOfAMissingVersionIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try store()
        let material = try await savedImage(store, name: "hero")
        let missing = MaterialReference(materialID: material.id, versionID: UUID())

        await #expect(throws: MaterialError.self) {
            try await store.addEditedVersion(of: missing, file: folder.appending(path: "x.png"))
        }
        #expect(try await store.material(id: material.id)?.versions.count == 1)
    }
}
