import Foundation

/// What tells one version of a file from another without reading it. A file replaced by another one gets a new
/// `resourceID` (device and inode) even when its size and modification date match.
public struct FileFingerprint: Codable, Sendable, Hashable {
    public var size: Int64
    public var modificationDate: Date
    public var resourceID: String

    public init(size: Int64, modificationDate: Date, resourceID: String) {
        self.size = size
        self.modificationDate = modificationDate
        self.resourceID = resourceID
    }

    /// The fingerprint of the file at `url` as it is now.
    public init(ofFileAt url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        self.init(size: size.int64Value, modificationDate: date, resourceID: "\(device):\(inode)")
    }
}

/// Content hashes by path and `FileFingerprint`, so an unchanged file is read once: a changed size, modification
/// date or resource ID hashes it again. With a `storeURL` the hashes outlive the app; the least recently used
/// ones beyond `capacity` are forgotten.
public final class FileHashCache: @unchecked Sendable {
    // Safe: `entries` and `lastUse` are only touched under `lock`.
    private let lock = NSLock()
    private var entries: [String: Entry]?
    /// Orders uses for forgetting; the wall clock can repeat and go back.
    private var lastUse: UInt64 = 0
    private let storeURL: URL?
    private let capacity: Int

    struct Entry: Codable, Equatable {
        var fingerprint: FileFingerprint
        var hash: String
        var lastUse: UInt64
    }

    public init(storeURL: URL? = nil, capacity: Int = 512) {
        self.storeURL = storeURL
        self.capacity = capacity
    }

    /// The hash of the file at `url`, from the cache or else from `compute`, which reads the file.
    /// A file that changes while `compute` runs isn't cached.
    public func hash(ofFileAt url: URL, compute: (URL) throws -> String) throws -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let before = try FileFingerprint(ofFileAt: url)
        if let cached = cachedHash(path: path, fingerprint: before) { return cached }

        let hash = try compute(url)
        guard (try? FileFingerprint(ofFileAt: url)) == before else { return hash }
        store(fingerprint: before, hash: hash, path: path)
        return hash
    }

    private func cachedHash(path: String, fingerprint: FileFingerprint) -> String? {
        lock.withLock {
            guard var entry = loadedEntries()[path], entry.fingerprint == fingerprint else { return nil }
            lastUse += 1
            entry.lastUse = lastUse
            entries?[path] = entry
            return entry.hash
        }
    }

    private func store(fingerprint: FileFingerprint, hash: String, path: String) {
        lock.withLock {
            var current = loadedEntries()
            lastUse += 1
            current[path] = Entry(fingerprint: fingerprint, hash: hash, lastUse: lastUse)
            if current.count > capacity {
                let oldest = current.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(current.count - capacity)
                for (key, _) in oldest { current[key] = nil }
            }
            entries = current
            save(current)
        }
    }

    /// Call with `lock` held.
    private func loadedEntries() -> [String: Entry] {
        if let entries { return entries }
        let data = storeURL.flatMap { try? Data(contentsOf: $0) }
        let loaded = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded
        lastUse = loaded.values.map(\.lastUse).max() ?? 0
        return loaded
    }

    /// Best effort: a hash that isn't saved is computed again next launch. Call with `lock` held.
    private func save(_ snapshot: [String: Entry]) {
        guard let storeURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
