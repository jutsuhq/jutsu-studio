import Foundation
import JutsuCore
import Persistence
import Presentation
import Testing

/// Compare with Original and the files Delete from Library takes, on items as the catalog stores them: a material's
/// first version has the material's own ID, and so has its Library item.
@Suite struct MaterialVersionsStoreTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "MaterialVersions-\(UUID())")
    private let store: SwiftDataStore

    init() throws {
        store = SwiftDataStore(modelContainer: try StoreContainer.make(inMemory: true))
    }

    private func file(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func aFinishedVideoWithANewVersionComparesWithItsOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var job = makeJob(state: .done)
        job.outputFile = try file("rooftop.mp4")
        try await store.save(job)
        let original = try #require(try await store.material(id: job.id))

        try await store.addEditedVersion(of: original.reference, file: try file("rooftop 4x.mp4"))
        let material = try #require(try await store.material(id: job.id))
        guard case .video(let item)? = MaterialLibrary.row(material) else {
            Issue.record("no video row")
            return
        }

        #expect(item.id == original.current.id)
        let pair = try #require(MaterialVersions.videoPair(material, current: item, exists: exists))
        #expect(pair.left.outputFile?.lastPathComponent == "rooftop.mp4")
        #expect(pair.right.outputFile?.lastPathComponent == "rooftop 4x.mp4")
        #expect(pair.left.id != pair.right.id)
        #expect(pair.tracks.map { $0.labels.first } == [ComparePair.originalLabel, ComparePair.editedLabel])
    }

    @Test func aSavedImageWithANewVersionComparesWithItsOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try await store.saveImage(
            SavedImage(
                fileURL: try file("lighthouse.png"), prompt: "a lighthouse", model: "soul", aspectRatio: "1:1",
                createdAt: Date(timeIntervalSince1970: 1)),
            remote: nil, generation: MaterialGeneration(prompt: "a lighthouse", model: "soul", parameters: nil),
            inputs: [], variantGroupID: nil)

        let material = try await store.addEditedVersion(of: saved.reference, file: try file("lighthouse 4x.png"))
        let image = try #require(MaterialLibrary.savedImage(material))

        #expect(image.id == saved.current.id)
        let pair = try #require(MaterialVersions.imagePair(material, current: image, exists: exists))
        #expect(pair.left.fileURL.lastPathComponent == "lighthouse.png")
        #expect(pair.right.fileURL.lastPathComponent == "lighthouse 4x.png")
    }

    @Test func aVersionADeliverySetHoldsStaysOnDelete() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var job = makeJob(state: .done)
        job.outputFile = try file("rooftop.mp4")
        try await store.save(job)
        let original = try #require(try await store.material(id: job.id))
        try await store.saveDeliverySet(DeliverySet(name: "Client", items: DeliverySet.items(from: [original])))
        let once = try await store.addEditedVersion(of: original.reference, file: try file("rooftop 4x.mp4"))
        let twice = try await store.addEditedVersion(of: once.reference, file: try file("rooftop 4x 60fps.mp4"))
        let owns = { (url: URL) in url.path.hasPrefix(folder.path) }

        let held = MaterialVersions.held(by: try await store.deliverySets())
        let files = MaterialVersions.earlierFiles(of: twice, held: held, owns: owns)

        #expect(files.map(\.lastPathComponent) == ["rooftop 4x.mp4"])
    }

    @Test func aRunOnThisMacDoesNotBringBackADeletedItem() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try await store.saveImage(
            SavedImage(
                fileURL: try file("lighthouse.png"), prompt: "a lighthouse", model: "soul", aspectRatio: "1:1",
                createdAt: Date(timeIntervalSince1970: 1)),
            remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        try await store.removeMaterials([saved.id])

        await #expect(throws: MaterialError.self) {
            try await store.addEditedVersion(of: saved.reference, file: try file("lighthouse 4x.png"), relists: false)
        }
        #expect(try await store.material(id: saved.id)?.isHidden == true)
        #expect(try await store.material(id: saved.id)?.versions.count == 1)
    }
}
