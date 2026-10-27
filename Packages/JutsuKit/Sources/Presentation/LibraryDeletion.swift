import Foundation
import JutsuCore

/// Where a deleted result's file goes. The app moves it to the Trash with `FileLayout.moveToTrash`.
public protocol LibraryTrash {
    /// Whether there is a file at `url` to move.
    func fileExists(at url: URL) -> Bool
    func moveToTrash(_ url: URL) throws
}

/// The stored records of library results. The app removes `MaterialRecord`s from its main context.
@MainActor
public protocol LibraryRecords {
    /// Marks the record of the result with `id` for removal; nothing for a result without one. `save()` removes it.
    func delete(_ id: UUID)
    func save() throws
}

/// Delete from Library: each file goes to the Trash first, then its record is removed. A record whose file couldn't
/// be moved is kept, so nothing is lost silently.
public enum LibraryDeletion {
    /// Stops the runs on this Mac started on `items` (`OnDeviceRuns.stop`) and waits for them, so no result lands on
    /// an item already in the Trash, then deletes them as below.
    @MainActor
    public static func delete(
        _ items: [LibraryItemModel], stopping runs: OnDeviceRuns, trash: any LibraryTrash, records: any LibraryRecords,
        earlierFiles: (UUID) -> [URL] = { _ in [] }
    ) async -> UserMessage? {
        await runs.stop(Set(items.map(\.id)))
        return delete(items, trash: trash, records: records, earlierFiles: earlierFiles)
    }

    /// Deletes `items` and returns what to tell the user when something was left; `nil` when everything was deleted.
    /// An item without a record only loses its file.
    /// - Parameter earlierFiles: the files of an item's earlier versions the app keeps
    ///   (`MaterialVersions.earlierFiles`), which go to the Trash before its current file.
    @MainActor
    public static func delete(
        _ items: [LibraryItemModel], trash: any LibraryTrash, records: any LibraryRecords,
        earlierFiles: (UUID) -> [URL] = { _ in [] }
    ) -> UserMessage? {
        var notTrashed: [any Error] = []
        for item in items {
            do {
                for url in earlierFiles(item.id) + [item.outputFile].compactMap(\.self) where trash.fileExists(at: url)
                {
                    try trash.moveToTrash(url)
                }
            } catch {
                notTrashed.append(error)
                continue
            }
            records.delete(item.id)
        }
        do {
            try records.save()
        } catch {
            return UserMessage(
                title: String(localized: "Can't remove the result from the Library", bundle: .module),
                message: error.localizedDescription)
        }
        switch notTrashed.count {
        case 0:
            return nil
        case 1:
            return UserMessage(
                title: String(localized: "Can't move the file to the Trash", bundle: .module),
                message: notTrashed[0].localizedDescription)
        case let count:
            return UserMessage(
                title: String(localized: "Can't move \(count) files to the Trash", bundle: .module),
                message: String(
                    localized: "They stay in the Library. \(notTrashed[0].localizedDescription)", bundle: .module))
        }
    }
}
