import Foundation

/// Custom output folders that earlier results were saved in, other than the current one. In the sandbox a result
/// is a plain URL that is readable only while its folder's security-scoped bookmark is resolved and accessed, so
/// every folder a result still lives in keeps its bookmark here after the user picks another one.
public struct OutputFolderHistory: Sendable, Hashable, Codable {
    public struct Folder: Sendable, Hashable, Codable {
        /// Where the folder was when its bookmark last resolved; results are matched against it, so a folder whose
        /// drive is unplugged is still known to hold them.
        public var path: String
        public var bookmark: Data

        public init(url: URL, bookmark: Data) {
            path = OutputFolderHistory.path(of: url)
            self.bookmark = bookmark
        }

        /// Whether `url` is this folder or lies inside it.
        public func contains(_ url: URL) -> Bool {
            OutputFolderHistory.folder(at: path, contains: url)
        }
    }

    public private(set) var folders: [Folder]

    public init(folders: [Folder] = []) {
        self.folders = folders
    }

    /// The history stored by `encoded()`; empty when nothing or something unreadable is stored.
    public init(stored data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Whether `url` is the folder at `folderPath` (as `path(of:)` gives it) or lies inside it.
    public static func folder(at folderPath: String, contains url: URL) -> Bool {
        let other = path(of: url)
        return other == folderPath || other.hasPrefix(folderPath + "/")
    }

    /// How a folder is identified here: its standardized path without a trailing slash.
    public static func path(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public var urls: [URL] {
        folders.map { URL(filePath: $0.path, directoryHint: .isDirectory) }
    }

    /// Remembers a folder the user switched away from, replacing an older entry for the same folder.
    public mutating func add(_ folder: Folder) {
        folders.removeAll { $0.path == folder.path }
        folders.append(folder)
    }

    /// Forgets the folder at `url`, e.g. because it is the current folder again. Returns whether it was there.
    @discardableResult
    public mutating func remove(_ url: URL) -> Bool {
        let path = Self.path(of: url)
        let count = folders.count
        folders.removeAll { $0.path == path }
        return folders.count != count
    }

    /// Resolves every bookmark and returns the folders to open. A stale bookmark is replaced and a moved folder's
    /// path updated; a folder that doesn't resolve is kept, since an unplugged drive may be back on the next launch.
    public mutating func resolve(with resolver: (Data) throws -> ResolvedBookmark) -> [URL] {
        var resolved: [URL] = []
        for index in folders.indices {
            guard let bookmark = try? resolver(folders[index].bookmark) else { continue }
            folders[index] = Folder(url: bookmark.url, bookmark: bookmark.refreshedData ?? folders[index].bookmark)
            resolved.append(bookmark.url)
        }
        return resolved
    }

    /// Drops the folders among `candidates` that hold none of `files` (results and active jobs' download folders)
    /// and returns them. Folders added after `candidates` was taken are kept: `files` may predate their results.
    public mutating func prune(_ candidates: [URL], keeping files: [URL]) -> [URL] {
        let candidatePaths = Set(candidates.map(Self.path(of:)))
        var dropped: [URL] = []
        folders.removeAll { folder in
            guard candidatePaths.contains(folder.path), !files.contains(where: folder.contains) else { return false }
            dropped.append(URL(filePath: folder.path, directoryHint: .isDirectory))
            return true
        }
        return dropped
    }
}
