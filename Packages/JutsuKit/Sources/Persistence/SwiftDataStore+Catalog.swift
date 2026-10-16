import Foundation
import JutsuCore
import SwiftData

extension SwiftDataStore {
    /// A damaged entry is reported, never omitted or overwritten with an empty library.
    public func materials() throws -> [Material] {
        try modelContext.fetch(FetchDescriptor<MaterialRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            .map { try $0.material() }
    }

    public func material(id: UUID) throws -> Material? { try materialRecord(id: id)?.material() }

    public func material(remote: MaterialRemote) throws -> Material? {
        let key = remote.key
        return try modelContext.fetch(FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.remoteKey == key }))
            .first?.material()
    }

    @discardableResult
    public func saveMaterial(_ proposed: Material) throws -> Material {
        do {
            if let existing = try materialRecord(id: proposed.id) {
                _ = try existing.material()
                try existing.update(proposed)
                try modelContext.save()
                return proposed
            }
            let saved = try upsertMaterial(proposed)
            try modelContext.save()
            return saved
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func setMaterialStarred(_ starred: Bool, ids: Set<UUID>) throws {
        do {
            for id in ids { try materialRecord(id: id)?.isStarred = starred }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Keep the entry as a source of other versions, but stop listing its local file.
    public func removeMaterials(_ ids: Set<UUID>) throws {
        do {
            for id in ids {
                if let record = try materialRecord(id: id) {
                    var material = try record.material()
                    material.removeFromLibrary()
                    try record.update(material)
                }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Sets the culling of each version; one whose material or version is gone is skipped. All or nothing.
    public func setCulling(_ changes: [MaterialReference: Culling]) throws {
        do {
            for (materialID, versions) in Dictionary(grouping: changes, by: \.key.materialID) {
                guard let record = try materialRecord(id: materialID) else { continue }
                var material = try record.material()
                for (reference, culling) in versions {
                    guard var version = material.versions.first(where: { $0.id == reference.versionID }) else {
                        continue
                    }
                    version.culling = culling
                    try material.updateVersion(version)
                }
                try record.update(material, updateStar: false)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Makes the material the face of its variant group; every other member stops being it.
    public func makeVariantPrimary(_ id: UUID) throws {
        do {
            guard let chosen = try materialRecord(id: id), let group = chosen.variantGroupID else {
                throw MaterialError.missingMaterial
            }
            let members = try modelContext.fetch(
                FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.variantGroupID == group }))
            for record in members {
                var material = try record.material()
                let isPrimary = record.id == id
                guard material.isVariantPrimary != isPrimary else { continue }
                material.isVariantPrimary = isPrimary
                try record.update(material, updateStar: false)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    public func madeFrom(_ reference: MaterialReference) throws -> [MaterialInput] {
        try material(id: reference.materialID)?.versions.first { $0.id == reference.versionID }?.inputs ?? []
    }

    public func usedIn(_ reference: MaterialReference) throws -> [MaterialReference] {
        try materials().flatMap { material in
            material.versions.filter { $0.inputs.contains { $0.source == reference } }.map {
                MaterialReference(materialID: material.id, versionID: $0.id)
            }
        }
    }

    func materialRecord(id: UUID) throws -> MaterialRecord? {
        var descriptor = FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @discardableResult
    func upsertMaterial(_ proposed: Material) throws -> Material {
        var value = proposed
        let known = try material(id: value.id) ?? value.remote.flatMap { try material(remote: $0) }
        if let known {
            value.id = known.id
            let original = known.versions[0]
            // Refreshing a remote listing must not discard a downloaded file, versions or exact request inputs.
            if value.current.fileURL == nil { value.current.fileURL = original.fileURL }
            value.current.remoteURL = value.current.remoteURL ?? original.remoteURL
            value.current.id = original.id
            // Culling is the user's verdict; a refreshed listing knows nothing of it.
            value.current.culling = original.culling
            if value.current.generation?.parameters == nil, let generation = original.generation {
                value.current.generation = generation
            }
            if value.current.inputs.isEmpty { value.current.inputs = original.inputs }
            value.current.bookmark = value.current.bookmark ?? original.bookmark
            value.current.pixelSize = value.current.pixelSize ?? original.pixelSize
            value.current.aspectRatio = value.current.aspectRatio ?? original.aspectRatio
            if var job = value.current.video {
                if let local = original.video, job.outputFile == nil { job = local }
                value.current.video = job
            }
            var updated = known
            try updated.updateVersion(value.current)
            updated.remote = value.remote ?? known.remote
            updated.variantGroupID = value.variantGroupID ?? known.variantGroupID
            // Saving a file again lists a material the user removed earlier.
            if !proposed.isHidden, proposed.current.fileURL != nil { updated.isHidden = false }
            // Stars on a local result are user edits; a remote listing updates likes separately.
            updated.isStarred = known.isStarred
            value = updated
        }
        if let record = try materialRecord(id: value.id) {
            try record.update(value, updateStar: false)
        } else {
            modelContext.insert(try MaterialRecord(value))
        }
        return value
    }

    func inputMaterial(
        file: URL, kind: Material.Kind, bookmark: Data?, reference: MaterialReference?
    ) throws -> MaterialReference {
        if let reference { return reference }
        let path = file.absoluteString
        if let found = try modelContext.fetch(
            FetchDescriptor<MaterialRecord>(predicate: #Predicate { $0.filePath == path })
        ).first {
            return try found.material().reference
        }
        let version = MaterialVersion(
            fileURL: file.isFileURL ? file : nil, remoteURL: file.isFileURL ? nil : file,
            bookmark: bookmark)
        var material = Material(kind: kind, version: version)
        material.isHidden = true
        return try upsertMaterial(material).reference
    }

    func inputs(of job: Job) throws -> [MaterialInput] {
        var inputs: [MaterialInput] = []
        if let parent = job.parentID {
            let reference =
                try material(id: parent)?.reference
                ?? MaterialReference(materialID: parent, versionID: parent)
            inputs.append(MaterialInput(source: reference, role: .parent))
        }
        if let source = job.spec.source {
            inputs.append(
                MaterialInput(
                    source: try inputMaterial(
                        file: source.fileURL, kind: .video, bookmark: source.bookmark, reference: source.material),
                    role: .sourceVideo))
        }
        for (position, image) in job.spec.references.enumerated() {
            let role: MaterialInput.Role = job.spec.usesFrames ? (position == 0 ? .startFrame : .endFrame) : .reference
            inputs.append(
                MaterialInput(
                    source: try inputMaterial(
                        file: image.fileURL, kind: .image, bookmark: image.bookmark, reference: image.material),
                    role: role, position: position))
        }
        return inputs
    }

    func registerVideo(_ job: Job, inputs: [MaterialInput]) throws {
        guard job.state == .done, let file = job.outputFile else { return }
        let generation = MaterialGeneration(
            prompt: job.spec.prompt, model: job.spec.model.rawValue,
            parameters: job.importedAt == nil ? try JSONEncoder().encode(job.spec) : nil)
        let remote = job.remote.map { MaterialRemote(provider: job.providerKind, owner: job.owner, id: $0.requestID) }
        let version = MaterialVersion(
            id: job.id, createdAt: job.finishedAt ?? job.createdAt, fileURL: file,
            generation: generation,
            inputs: inputs, video: job)
        try upsertMaterial(
            Material(
                id: job.id, kind: .video, origin: remote == nil ? .local : .higgsfield,
                remote: remote, createdAt: job.createdAt, variantGroupID: job.variantGroupID, version: version))
    }
}
