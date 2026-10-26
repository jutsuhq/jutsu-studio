import Foundation
import JutsuCore
import SwiftData

extension SwiftDataStore {
    // MARK: Delivery sets

    /// Every delivery set, newest first. A damaged entry is reported, never omitted.
    public func deliverySets() throws -> [DeliverySet] {
        try modelContext.fetch(DeliverySetRecord.newestFirst).map { try $0.deliverySet() }
    }

    /// Saves a new set or changes a stored one; a frozen set's versions never change (`DeliverySetError.frozen`).
    public func saveDeliverySet(_ set: DeliverySet) throws {
        try DeliverySetRecord.save(set, in: modelContext)
    }

    public func deleteDeliverySet(id: UUID) throws {
        do {
            try modelContext.delete(model: DeliverySetRecord.self, where: #Predicate { $0.id == id })
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: Edited versions

    /// Adds `file`, an edit of `source` made in another app and already copied into the output folder, as the new
    /// current version of the same material, linked to that exact version as its parent. The source version and its
    /// file are untouched, and so is every delivery set that holds it.
    /// - Parameter media: the file's length and size when known, as an on-device Enhance run reads them back; the
    ///   version then carries them rather than the source's.
    /// - Returns: the material with its new version.
    @discardableResult
    public func addEditedVersion(
        of source: MaterialReference, file: URL, media: OutputMedia? = nil, at date: Date = Date()
    ) throws -> Material {
        do {
            guard let record = try materialRecord(id: source.materialID) else { throw MaterialError.missingMaterial }
            var material = try record.material()
            guard let original = material.versions.first(where: { $0.id == source.versionID }) else {
                throw MaterialError.missingMaterial
            }
            // The prompt and model say what the picture shows; the parameters would claim the edit can be generated.
            let generation = original.generation.map { MaterialGeneration(prompt: $0.prompt, model: $0.model) }
            var video = original.video
            video?.outputFile = file
            if let media { video?.outputMedia = media }
            let version = MaterialVersion(
                createdAt: date, fileURL: file, generation: generation,
                inputs: [MaterialInput(source: source, role: .parent)], aspectRatio: media?.pixelSize.aspectLabel,
                pixelSize: media?.pixelSize, video: video)
            try material.addVersion(version)
            // An edit brought back lists the material again, like saving a file does.
            material.isHidden = false
            try record.update(material, updateStar: false)
            try modelContext.save()
            return material
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
