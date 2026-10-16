import Foundation
import JutsuCore

/// The JSON file of a log of work outside the job engine (`ImageSpendLog`, `CharacterSheetLog`, `ImageJobLog`), next
/// to the store. Financial callers use `readStrict`. For execution logs, a file with unreadable records gives the ones that can, and
/// is moved aside (`RecordList.asideURL`) so the next write doesn't erase the others: they may be paid job IDs.
/// A write throws, so the log can tell its callers and the user that its records exist only in memory.
struct LogFile<Record: Codable> {
    /// `nil` keeps everything in memory, as tests and previews do.
    let url: URL?

    init(folder: URL?, name: String) {
        url = folder?.appendingPathComponent(name)
    }

    func read() -> [Record] {
        guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let list = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(RecordList<Record>.self, from: $0) }
        if list == nil || list?.skipped != 0 {
            try? FileManager.default.moveItem(at: url, to: RecordList<Record>.asideURL(for: url))
        }
        return list?.records ?? []
    }

    /// Financial records must be complete. Keep an unreadable file in place so another launch cannot mistake
    /// an automatic backup for an empty spending history.
    func readStrict() throws(LogWriteError) -> [Record] {
        guard let url else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Record].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw LogWriteError(file: url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    func write(_ records: [Record]) throws(LogWriteError) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch {
            throw LogWriteError(file: url.lastPathComponent, reason: error.localizedDescription)
        }
    }
}

/// A log couldn't be written: what it holds is known to this launch only, until a later write goes through.
public struct LogWriteError: LocalizedError, Sendable, Hashable {
    /// The log's file name, e.g. "image-spend.json".
    public var file: String
    /// Why, as the file system said it: a full disk, a folder that can't be written.
    public var reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }

    public var errorDescription: String? {
        String(localized: "Jutsu Studio can't save \(file): \(reason)", bundle: .module)
    }
}
