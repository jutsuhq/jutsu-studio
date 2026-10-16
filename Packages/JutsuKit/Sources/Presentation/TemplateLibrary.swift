import Foundation
import JutsuCore

/// The stored templates. The app keeps them as `TemplateRecord`s in its main context.
@MainActor
public protocol TemplateRecords {
    /// The names of the stored templates other than the one with `id`; empty when they can't be read.
    func names(excluding id: UUID?) -> [String]
    /// Stores `template`. A failed save leaves the store as it was.
    func add(_ template: JobTemplate) throws
    /// Renames the template with `id` and saves; nothing when there is none.
    func rename(_ id: UUID, to name: String) throws
    /// Deletes the template with `id` and saves; nothing when there is none.
    func delete(_ id: UUID) throws
}

/// The copies of templates' reference images, each template's in a folder of its own.
public protocol TemplateImages {
    /// Copies the files of `references` into the template's folder and returns the copies in order. Nothing is left
    /// behind when a copy fails.
    func copy(_ references: [LocalImage], templateID: UUID) throws -> [URL]
    /// Deletes the template's copies. A failure is only logged; the next launch prunes what is left.
    func remove(templateID: UUID)
}

/// Saving, renaming and deleting templates, with the copies of their reference images kept in step.
@MainActor
public struct TemplateLibrary {
    let records: any TemplateRecords
    let images: any TemplateImages

    public init(records: any TemplateRecords, images: any TemplateImages) {
        self.records = records
        self.images = images
    }

    /// Saves `draft` under a unique name, with its reference images copied into the template's own folder. When the
    /// template can't be stored, the copies are removed again.
    @discardableResult
    public func save(_ draft: JobTemplate) throws -> JobTemplate {
        var template = draft
        template.name = TemplateNaming.uniqueName(draft.name, among: records.names(excluding: nil))
        let copies: [URL]
        do {
            copies = try images.copy(draft.references, templateID: template.id)
        } catch {
            throw TemplateSaveError.unreadableImage
        }
        // The copies live in the app container, which needs no bookmark. A generated image keeps its prompt.
        template.references = zip(copies, draft.references).map { LocalImage(fileURL: $0, prompt: $1.prompt) }
        do {
            try records.add(template)
        } catch {
            images.remove(templateID: template.id)
            throw error
        }
        return template
    }

    /// Renames to a unique name; returns the name it got.
    @discardableResult
    public func rename(_ id: UUID, to name: String) throws -> String {
        let unique = TemplateNaming.uniqueName(name, among: records.names(excluding: id))
        try records.rename(id, to: unique)
        return unique
    }

    /// Deletes the template, then its copied images; they stay when the template can't be deleted.
    public func delete(_ id: UUID) throws {
        try records.delete(id)
        images.remove(templateID: id)
    }
}

public enum TemplateSaveError: Error {
    case unreadableImage
}

extension UserMessage {
    /// For a failed save from Create or the Library.
    public static func templateNotSaved(_ error: any Error) -> UserMessage {
        let title = String(localized: "Can't save the template", bundle: .module)
        if error as? TemplateSaveError == .unreadableImage {
            return UserMessage(
                title: title,
                message: String(
                    localized: "A reference image can't be read. Add it again, then save the template.",
                    bundle: .module))
        }
        return UserMessage(title: title, message: error.localizedDescription)
    }
}
