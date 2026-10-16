import Foundation
import JutsuCore

/// Disk use shown in Settings › Storage.
public struct StorageUsage: Sendable, Hashable {
    /// Result files of library jobs that are still on disk; other files in the output folder don't count.
    public var results: Int64
    public var resultCount: Int
    public var sources: Int64
    public var cache: Int64
    /// Motion Library clips and account uploads downloaded to be used as inputs.
    public var media: Int64

    public init(results: Int64, resultCount: Int, sources: Int64, cache: Int64, media: Int64) {
        self.results = results
        self.resultCount = resultCount
        self.sources = sources
        self.cache = cache
        self.media = media
    }

    /// Everything Clear Cache deletes.
    public var cacheBytes: Int64 { sources + cache + media }

    /// Measured on a background thread.
    public static func measure(results: [URL], sources: URL, cache: URL, media: [URL]) async -> StorageUsage {
        await Task.detached(priority: .utility) {
            let sizes = Set(results).compactMap(CacheSize.fileBytes)
            return StorageUsage(
                results: sizes.reduce(0, +), resultCount: sizes.count,
                sources: CacheSize.measure([sources]), cache: CacheSize.measure([cache]),
                media: CacheSize.measure(media))
        }.value
    }

    /// "1.43 GB · 12 files", or "Empty".
    public var resultsText: String {
        guard resultCount > 0 else { return String(localized: "Empty", bundle: .module) }
        return "\(AppSettings.formatBytes(results)) · \(String(localized: "\(resultCount) files", bundle: .module))"
    }
}

/// A draft result old enough to go to the Trash.
public struct OldDraft: Sendable, Hashable {
    public let jobID: UUID
    public let file: URL
    public let bytes: Int64
}

public enum OldDrafts {
    public static let dayOptions = [7, 30, 90]
    public static let defaultDays = 30

    /// Finished drafts whose result is still on disk and that finished more than `days` days before `now`.
    /// - Parameter fileSize: the size of a file, `nil` when it is missing.
    public static func select(
        _ jobs: [Job], olderThan days: Int, now: Date, calendar: Calendar = .current,
        fileSize: (URL) -> Int64? = CacheSize.fileBytes
    ) -> [OldDraft] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        return jobs.compactMap { job in
            guard job.spec.isDraft, job.state.isTerminal, (job.finishedAt ?? job.createdAt) < cutoff,
                let file = job.outputFile, file.isFileURL, let bytes = fileSize(file)
            else { return nil }
            return OldDraft(jobID: job.id, file: file, bytes: bytes)
        }
    }

    /// `select` with real file sizes, on a background thread.
    public static func find(_ jobs: [Job], olderThan days: Int, now: Date = Date()) async -> [OldDraft] {
        await Task.detached(priority: .utility) { select(jobs, olderThan: days, now: now) }.value
    }

    /// "3 drafts · 1.43 GB", or "None".
    public static func summary(_ drafts: [OldDraft]) -> String {
        guard !drafts.isEmpty else { return String(localized: "None", bundle: .module) }
        return "\(countText(drafts)) · \(sizeText(drafts))"
    }

    /// The question asked before anything moves; `nil` when there is nothing to remove.
    public static func confirmation(_ drafts: [OldDraft], days: Int) -> Confirmation? {
        guard !drafts.isEmpty else { return nil }
        let count = countText(drafts)
        return Confirmation(
            title: String(localized: "Move \(count) to the Trash?", bundle: .module),
            message: String(
                localized: """
                    \(count) older than \(days) days, \(sizeText(drafts)) in total. \
                    The library keeps their jobs, inputs and costs and shows the files as missing.
                    """, bundle: .module))
    }

    private static func countText(_ drafts: [OldDraft]) -> String {
        String(localized: "\(drafts.count) drafts", bundle: .module)
    }

    private static func sizeText(_ drafts: [OldDraft]) -> String {
        AppSettings.formatBytes(drafts.reduce(0) { $0 + $1.bytes })
    }

    public struct Confirmation: Sendable, Hashable {
        public let title: String
        public let message: String
    }
}

extension CacheSize {
    /// The size of a regular file; `nil` when it is missing or not a regular file.
    public static func fileBytes(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else { return nil }
        return Int64(values.fileSize ?? 0)
    }
}
