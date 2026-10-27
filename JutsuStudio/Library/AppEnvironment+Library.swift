import Foundation
import MediaKit
import Persistence
import Presentation

extension AppEnvironment {
    func reopenCatalogFiles() async {
        do {
            materialAccess = try await store.materials().flatMap(\.versions).compactMap { version in
                guard let file = version.fileURL, let bookmark = version.bookmark else { return nil }
                return SecurityScopedAccess(url: file, bookmark: bookmark)
            }
        } catch {
            libraryLogger.error("Can't reopen catalog files: \(String(describing: error), privacy: .private)")
        }
    }

    /// Deletes results from the library as `LibraryDeletion` does; returns what to tell the user when something was
    /// left, `nil` when everything was deleted.
    /// - Parameter records: the stored records of `items`; an item without one only loses its file.
    func deleteFromLibrary(_ items: [LibraryItemModel], records: [MaterialRecord]) async -> UserMessage? {
        let outputFolder = outputFolder
        // None of the earlier files while the delivery sets, which keep their versions, can't be read.
        let held = try? await MaterialVersions.held(by: store.deliverySets())
        return await LibraryDeletion.delete(
            items, stopping: onDevice, trash: ResultTrash(),
            records: LibraryRecordStore(records: records, context: modelContainer.mainContext),
            earlierFiles: { id in
                guard let held, let material = try? records.first(where: { $0.id == id })?.material() else {
                    return []
                }
                return MaterialVersions.earlierFiles(of: material, held: held, owns: outputFolder.owns)
            })
    }

    /// Whether the star of a result can change here: a local result, or one in the account's history whose like
    /// it follows.
    func canStar(_ item: LibraryItemModel) -> Bool {
        libraryStarring.canStar(item)
    }
}
