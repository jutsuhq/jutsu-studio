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
    func deleteFromLibrary(_ items: [LibraryItemModel], records: [MaterialRecord]) -> UserMessage? {
        LibraryDeletion.delete(
            items, trash: ResultTrash(),
            records: LibraryRecordStore(records: records, context: modelContainer.mainContext))
    }

    /// Whether the star of a result can change here: a local result, or one in the account's history whose like
    /// it follows.
    func canStar(_ item: LibraryItemModel) -> Bool {
        libraryStarring.canStar(item)
    }
}
