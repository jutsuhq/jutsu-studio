import Foundation
import JobEngine
import JutsuCore
import Persistence
import Presentation
import SwiftData
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "History")

extension AppEnvironment {
    /// Loads the first page of the account's history again, or the next one. Pages that hold nothing the
    /// library shows are skipped over. Does nothing without an account connection.
    func loadHistory(refresh: Bool) async {
        guard let source = generationHistory, var request = history.beginLoad(refresh: refresh)
        else { return }
        let owner = provider?.owner
        let generation = providerGeneration
        while true {
            do {
                let response = try await source.history(after: request.cursor)
                guard generation == providerGeneration else { return }
                let page = try await store.cacheHistory(response, owner: owner)
                guard history.receive(page, for: request), let next = history.beginLoad(refresh: false) else {
                    return
                }
                request = next
            } catch {
                if error as? ProviderError == .unauthorized { connection.markNeedsAttention() }
                logger.error("Can't load the history: \(String(describing: error), privacy: .private)")
                history.fail(error, for: request)
                return
            }
        }
    }

    /// Downloads a history item's result into the output folder and adds it to the library as a finished job.
    /// Returns the stored job; an item imported before is not downloaded again.
    @discardableResult
    func importHistory(_ item: HistoryItem) async throws -> Job {
        importingHistory.insert(item.id)
        defer { importingHistory.remove(item.id) }
        let job = Job(importing: item, owner: provider?.owner, importedAt: .now)
        do {
            return try await engine.importFinished(job, from: item.outputURL)
        } catch {
            // CDN URLs carry the account's user ID.
            logger.error(
                "Can't import \(item.outputURL.absoluteString, privacy: .private): \(String(describing: error), privacy: .private)"
            )
            throw error
        }
    }
}

extension AppEnvironment {
    /// The star and like rules of the active connection.
    var libraryStarring: LibraryStarring {
        LibraryStarring(likes: generationLikes, owner: provider?.owner)
    }

    /// Whether starring the item also likes it on the connected account.
    func syncsLike(_ item: LibraryItemModel) -> Bool {
        libraryStarring.syncsLike(item)
    }

    /// Stars or unstars a result and likes or unlikes it on Higgsfield to match, as `LibraryStarring` does.
    func setStarred(_ isStarred: Bool, for item: LibraryItemModel, record: MaterialRecord?) async throws {
        let store = LibraryRecordStore(records: record.map { [$0] } ?? [], context: modelContainer.mainContext)
        try await reportingLikeFailure {
            try await libraryStarring.setStarred(isStarred, for: item, in: store) { history.setLiked($0, $1) }
        }
    }

    /// Stars or unstars each result that isn't so already; the first like Higgsfield refuses stops the rest.
    /// - Parameter records: the stored records of `items`.
    func setStarred(_ isStarred: Bool, _ items: [LibraryItemModel], records: [MaterialRecord]) async throws {
        let store = LibraryRecordStore(records: records, context: modelContainer.mainContext)
        try await reportingLikeFailure {
            try await libraryStarring.setStarred(isStarred, items, in: store) { history.setLiked($0, $1) }
        }
    }

    /// Likes or unlikes account images to match their stars; the first like Higgsfield refuses stops the rest.
    /// Without an account connection there is nothing to like on, so nothing happens.
    func setImageLiked(_ isLiked: Bool, for images: [HistoryImageItem]) async throws {
        guard let likes = generationLikes else { return }
        try await reportingLikeFailure {
            for image in images {
                try await likes.setLiked(image.id, isLiked)
                history.setLiked(image.id, isLiked)
                try await store.setMaterialStarred(isLiked, ids: [image.jobID])
            }
        }
    }

    /// Flags the connection on 401 and logs a like Higgsfield refused, then rethrows it.
    private func reportingLikeFailure(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            if error as? ProviderError == .unauthorized { connection.markNeedsAttention() }
            logger.error("Can't set a like: \(String(describing: error), privacy: .private)")
            throw error
        }
    }
}
