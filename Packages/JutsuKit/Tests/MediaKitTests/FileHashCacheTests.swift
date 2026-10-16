import Foundation
import Testing

@testable import MediaKit

@Suite struct FileHashCacheTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FileHashCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Hashes with a counter, so a test sees which calls read the file.
    private final class Hasher {
        var reads = 0

        func hash(_ cache: FileHashCache, _ url: URL) throws -> String {
            try cache.hash(ofFileAt: url) { url in
                reads += 1
                return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            }
        }
    }

    private func file(
        _ name: String, _ text: String, modified: Date = Date(timeIntervalSince1970: 1_000_000)
    ) throws
        -> URL
    {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try setModified(url, modified)
        return url
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func anUnchangedFileIsReadOnce() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file("a", "one")
        let cache = FileHashCache()
        let hasher = Hasher()

        #expect(try hasher.hash(cache, url) == "one")
        #expect(try hasher.hash(cache, url) == "one")
        #expect(hasher.reads == 1)
    }

    @Test func aNewSizeIsReadAgain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file("a", "one")
        let cache = FileHashCache()
        let hasher = Hasher()
        _ = try hasher.hash(cache, url)

        _ = try file("a", "three")

        #expect(try hasher.hash(cache, url) == "three")
        #expect(hasher.reads == 2)
    }

    @Test func aNewModificationDateIsReadAgain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file("a", "one")
        let cache = FileHashCache()
        let hasher = Hasher()
        _ = try hasher.hash(cache, url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data("two".utf8))
        try handle.close()
        try setModified(url, Date(timeIntervalSince1970: 2_000_000))

        #expect(try hasher.hash(cache, url) == "two")
        #expect(hasher.reads == 2)
    }

    @Test func aReplacedFileIsReadAgainWhenSizeAndDateMatch() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file("a", "one")
        let cache = FileHashCache()
        let hasher = Hasher()
        _ = try hasher.hash(cache, url)
        let original = try FileFingerprint(ofFileAt: url)

        let replacement = try file("b", "two")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        let replaced = try FileFingerprint(ofFileAt: url)

        #expect(replaced.size == original.size && replaced.modificationDate == original.modificationDate)
        #expect(replaced.resourceID != original.resourceID)
        #expect(try hasher.hash(cache, url) == "two")
        #expect(hasher.reads == 2)
    }

    @Test func aFileChangedWhileHashingIsNotCached() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file("a", "one")
        let cache = FileHashCache()
        var reads = 0

        for _ in 0..<2 {
            _ = try cache.hash(ofFileAt: url) { url in
                reads += 1
                try setModified(url, Date(timeIntervalSince1970: 1_000_000 + Double(reads)))
                return "stale"
            }
        }

        #expect(reads == 2)
    }

    @Test func savedHashesOutliveTheCache() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try file("a", "one")
        let store = folder.appendingPathComponent("store/hashes.json")
        let hasher = Hasher()
        _ = try hasher.hash(FileHashCache(storeURL: store), url)

        #expect(try hasher.hash(FileHashCache(storeURL: store), url) == "one")
        #expect(hasher.reads == 1)
        _ = try file("a", "three")
        #expect(try hasher.hash(FileHashCache(storeURL: store), url) == "three")
        #expect(hasher.reads == 2)
    }

    @Test func theLeastRecentlyUsedHashIsForgottenBeyondCapacity() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try file("a", "one")
        let second = try file("b", "two")
        let third = try file("c", "three")
        let cache = FileHashCache(capacity: 2)
        let hasher = Hasher()
        _ = try hasher.hash(cache, first)
        _ = try hasher.hash(cache, second)
        _ = try hasher.hash(cache, first)

        _ = try hasher.hash(cache, third)
        _ = try hasher.hash(cache, first)
        #expect(hasher.reads == 3)
        _ = try hasher.hash(cache, second)
        #expect(hasher.reads == 4)
    }

    @Test func aMissingFileThrows() {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FileHashCache()

        #expect(throws: (any Error).self) {
            try cache.hash(ofFileAt: folder.appendingPathComponent("missing")) { _ in "never" }
        }
    }
}
