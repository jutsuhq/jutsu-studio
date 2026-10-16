import Foundation
import JutsuCore
import Persistence
import SwiftData
import Testing
import os

@Suite struct MaterialCatalogTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "Catalog-\(UUID())")
    private var layout: FileLayout { FileLayout(root: folder, defaultOutputFolder: folder.appending(path: "Media")) }

    private func image(_ name: String = "image") -> SavedImage {
        SavedImage(
            fileURL: folder.appending(path: "\(name).png"), prompt: "known prompt", model: "soul",
            aspectRatio: "16:9", createdAt: Date(timeIntervalSince1970: 1_000))
    }

    private func store() throws -> SwiftDataStore {
        try SwiftDataStore(modelContainer: StoreContainer.make(inMemory: true))
    }

    @Test func imageAndVideoSurviveReopeningWithMetadataStarsAndVersions() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try SwiftDataStore(modelContainer: StoreContainer.make(inMemory: false, layout: layout))
        let saved = image()
        let remote = MaterialRemote(provider: .account, owner: "alice", id: "remote-image")
        var material = try await first.saveImage(
            saved, remote: remote,
            generation: MaterialGeneration(prompt: saved.prompt, model: saved.model, parameters: Data("{}".utf8)),
            inputs: [], variantGroupID: UUID())
        let original = material.reference
        try material.addVersion(
            MaterialVersion(
                fileURL: folder.appending(path: "edit.png"),
                inputs: [MaterialInput(source: original, role: .parent)]))
        material = try await first.saveMaterial(material)
        try await first.setMaterialStarred(true, ids: [material.id])
        var job = makeJob(state: .done)
        job.outputFile = folder.appending(path: "video.mp4")
        try await first.save(job)

        let reopened = try SwiftDataStore(modelContainer: StoreContainer.make(inMemory: false, layout: layout))
        let restored = try #require(try await reopened.material(remote: remote))
        #expect(restored.id == material.id)
        #expect(restored.reference == material.reference)
        #expect(restored.isStarred)
        #expect(restored.versions.count == 2)
        #expect(restored.previousVersions.first?.generation?.parameters == Data("{}".utf8))
        #expect(try await reopened.madeFrom(restored.reference).map(\.source) == [original])
        #expect(try await reopened.material(id: job.id)?.current.video == job)
    }

    @Test func remoteIdentityDeduplicatesAcrossReloadsAndSeparatesOwners() async throws {
        let catalog = try store()
        let id = "same-remote-id"
        func page() -> HistoryPage {
            HistoryPage(
                items: [],
                images: [
                    HistoryImageItem(
                        id: id, model: "soul", createdAt: Date(),
                        outputURL: URL(string: "https://example.com/image.png")!)
                ], nextCursor: nil)
        }
        let first = try await catalog.cacheHistory(page(), owner: "alice")
        let again = try await catalog.cacheHistory(page(), owner: "alice")
        let bob = try await catalog.cacheHistory(page(), owner: "bob")
        #expect(first.images.first?.jobID == again.images.first?.jobID)
        #expect(first.images.first?.jobID != bob.images.first?.jobID)
        #expect(try await catalog.materials().count == 2)
        let local = image()
        let identity = MaterialRemote(provider: .account, owner: "alice", id: id)
        let imported = try await catalog.saveImage(
            local, remote: identity, generation: nil,
            inputs: [], variantGroupID: nil)
        #expect(imported.id == first.images.first?.jobID)
        _ = try await catalog.cacheHistory(page(), owner: "alice")
        let afterRefresh = try #require(try await catalog.material(remote: identity))
        #expect(afterRefresh.current.fileURL == local.fileURL)
        #expect(afterRefresh.reference == imported.reference)
        #expect(try await catalog.materials().count == 2)
        var edited = afterRefresh
        try edited.addVersion(MaterialVersion(fileURL: folder.appending(path: "edited.png")))
        _ = try await catalog.saveMaterial(edited)
        _ = try await catalog.cacheHistory(page(), owner: "alice")
        let refreshed = try #require(try await catalog.material(remote: identity))
        #expect(refreshed.reference == edited.reference)
        #expect(refreshed.versions.count == 2)
        #expect(refreshed.previousVersions.first?.fileURL == local.fileURL)
    }

    @Test func enqueuePinsAllInputVersionsAndRolesBeforeCompletion() async throws {
        let catalog = try store()
        let start = try await catalog.saveImage(
            image("start"), remote: nil, generation: nil,
            inputs: [], variantGroupID: nil)
        var end = try await catalog.saveImage(
            image("end"), remote: nil, generation: nil,
            inputs: [], variantGroupID: nil)
        let originalEnd = end.reference
        var job = makeJob()
        job.spec = JobSpec(
            mode: .motionTransfer, model: .seedance25, source: nil,
            references: [LocalImage(fileURL: image("start").fileURL), LocalImage(fileURL: image("end").fileURL)],
            resolution: .p720, length: 5, referencesAreFrames: true)
        try await catalog.save(job)
        try end.addVersion(MaterialVersion(fileURL: folder.appending(path: "new-end.png")))
        _ = try await catalog.saveMaterial(end)
        job.state = .done
        job.outputFile = folder.appending(path: "result.mp4")
        try await catalog.save(job)
        let output = try #require(try await catalog.material(id: job.id))
        let inputs = try await catalog.madeFrom(output.reference)
        #expect(inputs.map(\.role) == [.startFrame, .endFrame])
        #expect(inputs.map(\.source) == [start.reference, originalEnd])
        #expect(try await catalog.usedIn(originalEnd) == [output.reference])
        #expect(try await catalog.usedIn(end.reference).isEmpty)
    }

    /// Make Video pins the version it was asked for on the image (`LocalImage.material`): the relation names that
    /// version and the role it was given, even when the file at the path is a newer edit or is removed meanwhile.
    @Test func makeVideoRecordsThePinnedVersionWithItsRoleAtEnqueue() async throws {
        let catalog = try store()
        var picked = try await catalog.saveImage(
            image("picked"), remote: nil, generation: MaterialGeneration(prompt: "A knight", model: "soul"),
            inputs: [], variantGroupID: nil)
        let asked = picked.reference
        try picked.addVersion(MaterialVersion(fileURL: image("picked").fileURL))
        _ = try await catalog.saveMaterial(picked)
        var job = makeJob()
        job.spec.references = [LocalImage(fileURL: image("picked").fileURL, material: asked)]
        try await catalog.save(job)
        try await catalog.removeMaterials([picked.id])
        job.state = .done
        job.outputFile = folder.appending(path: "made.mp4")
        try await catalog.save(job)
        let video = try #require(try await catalog.material(id: job.id))
        let images = try await catalog.madeFrom(video.reference).filter { $0.role != .sourceVideo }
        #expect(images == [MaterialInput(source: asked, role: .reference)])
        #expect(try await catalog.usedIn(asked) == [video.reference])
        #expect(try await catalog.material(id: picked.id)?.isHidden == true)
    }

    @Test func draftFinalAndJoinedOutputKeepTheirSourcesAndVariantSiblings() async throws {
        let catalog = try store()
        var draft = makeJob(state: .done)
        draft.outputFile = folder.appending(path: "draft.mp4")
        draft.spec.isDraft = true
        draft.variantGroupID = UUID()
        try await catalog.save(draft)
        var sibling = makeJob(state: .done)
        sibling.variantGroupID = draft.variantGroupID
        sibling.outputFile = folder.appending(path: "variant.mp4")
        try await catalog.save(sibling)
        var final = makeJob(state: .done)
        final.parentID = draft.id
        final.spec.mode = .extend
        final.outputFile = folder.appending(path: "extend.mp4")
        try await catalog.save(final)
        try await catalog.saveJoinedVideo(from: final, output: folder.appending(path: "joined.mp4"))
        let materials = try await catalog.materials()
        let draftMaterial = try #require(materials.first { $0.id == draft.id })
        let siblingMaterial = try #require(materials.first { $0.id == sibling.id })
        let finalMaterial = try #require(materials.first { $0.id == final.id })
        let joined = try #require(materials.first { $0.current.fileURL?.lastPathComponent == "joined.mp4" })
        #expect(draftMaterial.variantGroupID == siblingMaterial.variantGroupID)
        #expect(draftMaterial.versions.count == 1 && siblingMaterial.versions.count == 1)
        #expect(try await catalog.madeFrom(finalMaterial.reference).contains { $0.source == draftMaterial.reference })
        #expect(try await catalog.madeFrom(joined.reference).contains { $0.source == finalMaterial.reference })
        #expect(try await catalog.job(id: joined.id) == nil)
    }

    @Test func unavailableFilesAndRemovedSourcesRetainRelations() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try store()
        let input = try await catalog.saveImage(image(), remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        var job = makeJob(state: .done)
        job.spec.references = [LocalImage(fileURL: image().fileURL, material: input.reference)]
        job.outputFile = folder.appending(path: "missing.mp4")
        try await catalog.save(job)
        try await catalog.removeMaterials([input.id])
        let kept = try #require(try await catalog.material(id: input.id))
        #expect(kept.isHidden)
        #expect(kept.current.availability == .unavailable)
        #expect(try await catalog.usedIn(input.reference).count == 1)
        #expect(try await catalog.material(id: job.id)?.current.availability == .unavailable)
        #expect(kept.current.generation == nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: image().fileURL)
        #expect(try await catalog.material(id: input.id)?.current.availability == .available)
        #expect(try await catalog.usedIn(input.reference).count == 1)
    }

    @Test func removedMaterialsAreListedAgainWhenSavedAgain() async throws {
        let catalog = try store()
        let remote = MaterialRemote(provider: .account, owner: "alice", id: "remote-image")
        var account = image("account")
        account.remoteURL = URL(string: "https://example.com/account.png")
        let imported = try await catalog.saveImage(
            account, remote: remote, generation: nil, inputs: [], variantGroupID: nil)
        let local = try await catalog.saveImage(
            image("local"), remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        try await catalog.removeMaterials([imported.id, local.id])

        // The account copy is listed from the account again; the local one leaves the Library.
        let removedAccount = try #require(try await catalog.material(id: imported.id))
        #expect(!removedAccount.isHidden)
        #expect(removedAccount.current.fileURL == nil)
        #expect(removedAccount.current.remoteURL == account.remoteURL)
        #expect(try await catalog.material(id: local.id)?.isHidden == true)

        let reimported = try await catalog.saveImage(
            account, remote: remote, generation: nil, inputs: [], variantGroupID: nil)
        #expect(reimported.id == imported.id)
        #expect(reimported.current.fileURL == account.fileURL)
        var again = image("local")
        again.id = local.id
        let resaved = try await catalog.saveImage(again, remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        #expect(!resaved.isHidden)
        #expect(try await catalog.materials().filter { !$0.isHidden }.count == 2)
    }

    @Test func corruptCatalogEntryThrowsWithoutReplacingIt() async throws {
        let catalog = try store()
        let saved = try await catalog.saveImage(image(), remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        let context = ModelContext(catalog.modelContainer)
        let record = try #require(try context.fetch(FetchDescriptor<MaterialRecord>()).first)
        let broken = Data("broken catalog entry".utf8)
        record.setValue(forKey: \.materialData, to: broken)
        try context.save()
        await #expect(throws: (any Error).self) { try await catalog.materials() }
        await #expect(throws: (any Error).self) { try await catalog.saveMaterial(saved) }
        #expect(
            try ModelContext(catalog.modelContainer).fetch(FetchDescriptor<MaterialRecord>()).first?.materialData
                == broken)
    }

    @Test func failedImageWriteRollsBackInputRegistration() async throws {
        let catalog = try store()
        var invalid = image()
        invalid.createdAt = Date(timeIntervalSince1970: .nan)
        await #expect(throws: (any Error).self) {
            try await catalog.saveImage(
                invalid, remote: nil, generation: nil,
                inputs: [LocalImage(fileURL: folder.appending(path: "reference.png"))], variantGroupID: nil)
        }
        #expect(try await catalog.materials().isEmpty)
        _ = try await catalog.saveImage(image(), remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        #expect(try await catalog.materials().count == 1)
    }

    @Test func cullingAndThePrimarySurviveReopeningAndRefreshes() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try SwiftDataStore(modelContainer: StoreContainer.make(inMemory: false, layout: layout))
        let group = UUID()
        var draft = makeJob(state: .done)
        draft.variantGroupID = group
        draft.outputFile = folder.appending(path: "first.mp4")
        try await first.save(draft)
        var sibling = makeJob(state: .done)
        sibling.variantGroupID = group
        sibling.outputFile = folder.appending(path: "second.mp4")
        try await first.save(sibling)
        let other = try await first.saveImage(image(), remote: nil, generation: nil, inputs: [], variantGroupID: nil)

        let draftReference = try #require(try await first.material(id: draft.id)).reference
        try await first.setCulling([draftReference: .rejected, other.reference: .kept])
        try await first.makeVariantPrimary(sibling.id)
        try await first.makeVariantPrimary(draft.id)
        // The engine saving the job again must not reset the verdict.
        try await first.save(draft)

        let reopened = try SwiftDataStore(modelContainer: StoreContainer.make(inMemory: false, layout: layout))
        let materials = try await reopened.materials()
        let restoredDraft = try #require(materials.first { $0.id == draft.id })
        let restoredSibling = try #require(materials.first { $0.id == sibling.id })
        #expect(restoredDraft.current.culling == .rejected)
        #expect(restoredSibling.current.culling == .unreviewed)
        #expect(materials.first { $0.id == other.id }?.current.culling == .kept)
        #expect(restoredDraft.isVariantPrimary)
        #expect(!restoredSibling.isVariantPrimary)
        await #expect(throws: MaterialError.self) { try await reopened.makeVariantPrimary(other.id) }
    }

    @Test func cullingIsPerVersion() async throws {
        let catalog = try store()
        var material = try await catalog.saveImage(
            image(), remote: nil, generation: nil, inputs: [], variantGroupID: nil)
        let original = material.reference
        try await catalog.setCulling([original: .rejected])
        material = try #require(try await catalog.material(id: material.id))
        try material.addVersion(MaterialVersion(fileURL: folder.appending(path: "edit.png")))
        material = try await catalog.saveMaterial(material)
        #expect(material.current.culling == .unreviewed)
        try await catalog.setCulling([material.reference: .kept])
        let restored = try #require(try await catalog.material(id: material.id))
        #expect(restored.versions.map(\.culling) == [.rejected, .kept])
    }

    @Test func loadsFiveThousandMaterialsWithinFiveSeconds() async throws {
        let catalog = try store()
        let context = ModelContext(catalog.modelContainer)
        for index in 0..<5_000 {
            let material = Material(
                kind: index.isMultiple(of: 2) ? .image : .video,
                version: MaterialVersion(fileURL: folder.appending(path: "\(index).png")))
            context.insert(try MaterialRecord(material))
        }
        try context.save()
        let clock = ContinuousClock()
        let start = clock.now
        let loaded = try await catalog.materials()
        let elapsed = start.duration(to: clock.now)
        #expect(loaded.count == 5_000)
        #expect(elapsed < .seconds(5))
        Logger(subsystem: "com.jutsustudio.tests", category: "Catalog").info(
            "Loaded 5,000 entries in \(elapsed.description, privacy: .private)")
    }
}
