import Foundation
import JutsuCore
import MediaKit
import Persistence
import Presentation
import SwiftData
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Templates")

extension AppEnvironment {
    /// The templates in the main context, with their images in the app container.
    private var templateLibrary: TemplateLibrary {
        TemplateLibrary(
            records: TemplateRecordStore(context: modelContainer.mainContext),
            images: TemplateImageFolder(layout: layout))
    }

    /// Starts Create from `template` on the side of its kind: a video template fills the video form, an image
    /// template Generate…'s form. A model the connection doesn't offer falls back, and Create's notice says so.
    /// - Parameter offeredModels: what the connection runs video jobs on; image models come from Generate… itself.
    func useTemplate(_ template: JobTemplate, offeredModels: Set<VideoModel>) {
        switch template.kind {
        case .image:
            navigation.templateNotice = referenceGenerator.applyImageTemplate(template)
            navigation.imageDraft = referenceGenerator.snapshot()
        case .video:
            navigation.templateNotice = navigation.replaceDraft { $0.apply(template, offered: offeredModels) }
        }
        navigation.createKind = template.kind
        navigation.selection = .create
    }

    /// Saves `draft` under a unique name, with its reference images copied into the template's own folder.
    @discardableResult
    func saveTemplate(_ draft: JobTemplate) throws -> JobTemplate {
        try templateLibrary.save(draft)
    }

    /// Renames to a unique name; returns the name it got.
    @discardableResult
    func renameTemplate(_ record: TemplateRecord, to name: String) throws -> String {
        try templateLibrary.rename(record.id, to: name)
    }

    /// Deletes the template and its copied images. Images left by a failed removal are pruned on the next launch.
    func deleteTemplate(_ record: TemplateRecord) throws {
        try templateLibrary.delete(record.id)
    }

    /// Removes image folders whose template is gone. Skipped when the templates can't be read,
    /// so a store error never deletes images that are still in use.
    func pruneTemplateImages() {
        do {
            let ids = try modelContainer.mainContext.fetch(TemplateRecord.byName).map(\.id)
            try layout.pruneTemplateImages(keeping: Set(ids))
        } catch {
            logger.error("Can't prune template images: \(String(describing: error), privacy: .private)")
        }
    }
}

/// `TemplateRecord`s in a context.
@MainActor
private struct TemplateRecordStore: TemplateRecords {
    let context: ModelContext

    func names(excluding id: UUID?) -> [String] {
        do {
            return try context.fetch(TemplateRecord.byName).filter { $0.id != id }.map(\.name)
        } catch {
            logger.error("Can't read template names: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// A record whose save fails is taken out of the context again.
    func add(_ template: JobTemplate) throws {
        let record = try TemplateRecord(template: template)
        context.insert(record)
        do {
            try context.save()
        } catch {
            context.delete(record)
            throw error
        }
    }

    func rename(_ id: UUID, to name: String) throws {
        guard let record = try record(id) else { return }
        try record.rename(to: name)
        try context.save()
    }

    func delete(_ id: UUID) throws {
        guard let record = try record(id) else { return }
        context.delete(record)
        try context.save()
    }

    private func record(_ id: UUID) throws -> TemplateRecord? {
        var descriptor = FetchDescriptor<TemplateRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

/// Template images in `templates/<id>/`, copied with sandbox access to the originals.
private struct TemplateImageFolder: TemplateImages {
    let layout: FileLayout

    func copy(_ references: [LocalImage], templateID: UUID) throws -> [URL] {
        let accesses = references.map { SecurityScopedAccess(url: $0.fileURL, bookmark: $0.bookmark) }
        do {
            return try withExtendedLifetime(accesses) {
                try layout.copyTemplateImages(accesses.map(\.url), templateID: templateID)
            }
        } catch {
            logger.error("Can't copy template images: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    func remove(templateID: UUID) {
        do {
            try layout.removeTemplateImages(templateID: templateID)
        } catch {
            logger.error("Can't remove template images: \(String(describing: error), privacy: .private)")
        }
    }
}
