import Foundation
import Persistence
import Presentation
import SwiftData
import os

let libraryLogger = Logger(subsystem: "com.jutsustudio", category: "Library")

/// The library's results as `MaterialRecord`s of the main context: their stars, and their visibility on Delete from Library.
@MainActor
final class LibraryRecordStore: LibraryStarStore, LibraryRecords {
    /// The stored records of the results acted on.
    let records: [MaterialRecord]
    let context: ModelContext
    private var failure: (any Error)?

    init(records: [MaterialRecord], context: ModelContext) {
        self.records = records
        self.context = context
    }

    /// Saves at once; failed writes are reported.
    func setStarred(_ isStarred: Bool, for id: UUID) throws {
        guard let record = record(id) else { return }
        record.isStarred = isStarred
        do {
            try context.save()
        } catch {
            context.rollback()
            libraryLogger.error("Can't save a star: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    func delete(_ id: UUID) {
        guard let record = record(id) else { return }
        do {
            var material = try record.material()
            material.removeFromLibrary()
            try record.update(material)
        } catch {
            failure = error
        }
    }

    func save() throws {
        do {
            if let failure { throw failure }
            try context.save()
        } catch {
            context.rollback()
            libraryLogger.error("Can't delete a library record: \(String(describing: error), privacy: .private)")
            throw error
        }
    }

    private func record(_ id: UUID) -> MaterialRecord? {
        records.first { $0.id == id }
    }
}

/// Deleted results go to the Trash, never straight away.
struct ResultTrash: LibraryTrash {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func moveToTrash(_ url: URL) throws {
        do {
            try FileLayout.moveToTrash(url)
        } catch {
            libraryLogger.error("Can't move a result to the Trash: \(String(describing: error), privacy: .private)")
            throw error
        }
    }
}
