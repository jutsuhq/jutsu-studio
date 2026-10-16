import Foundation
import JutsuCore

/// Where the app keeps its files. Both roots are injectable so tests never touch real folders.
public struct FileLayout: Sendable, Hashable {
    /// `Application Support/Jutsu Studio`, inside the sandbox container.
    public let root: URL
    /// Results go here unless the user picked a custom folder.
    public let defaultOutputFolder: URL

    public init(
        root: URL = URL.applicationSupportDirectory.appending(path: "Jutsu Studio", directoryHint: .isDirectory),
        defaultOutputFolder: URL = URL.moviesDirectory.appending(path: "Jutsu Studio", directoryHint: .isDirectory)
    ) {
        self.root = root
        self.defaultOutputFolder = defaultOutputFolder
    }

    public var storeURL: URL { root.appending(path: "default.store", directoryHint: .notDirectory) }
    /// The Create form between launches; not a cache.
    public var createDraftURL: URL { root.appending(path: "create-draft.json", directoryHint: .notDirectory) }
    /// Prepared inputs; safe to delete.
    public var sourcesFolder: URL { root.appending(path: "sources", directoryHint: .isDirectory) }
    public var cacheFolder: URL { root.appending(path: "cache", directoryHint: .isDirectory) }
    /// Preset catalog JSON and previews.
    public var presetCacheFolder: URL { cacheFolder.appending(path: "presets", directoryHint: .isDirectory) }
    /// Motion Library clips picked as sources. Queued jobs read them, so Clear Cache waits for an empty queue.
    public var motionLibraryFolder: URL { root.appending(path: "motion-library", directoryHint: .isDirectory) }
    /// Images and videos the account uploaded, downloaded to be used again; cleared like `motionLibraryFolder`.
    public var accountMediaFolder: URL { root.appending(path: "account-media", directoryHint: .isDirectory) }
    /// Images pasted into Create from the clipboard, saved to be used as references; cleared like
    /// `motionLibraryFolder`.
    public var pastedImagesFolder: URL { root.appending(path: "pasted", directoryHint: .isDirectory) }
    /// Videos and images downloaded from links pasted into Create, one folder per link; cleared like
    /// `pastedImagesFolder`.
    public var linkedMediaFolder: URL { root.appending(path: "links", directoryHint: .isDirectory) }
    /// Reference images made with Generate… and picked, one folder per image; cleared like `pastedImagesFolder`.
    public var generatedImagesFolder: URL { root.appending(path: "generated", directoryHint: .isDirectory) }
    /// Inputs downloaded on demand or pasted; Clear Cache deletes them.
    public var downloadedInputFolders: [URL] {
        [motionLibraryFolder, accountMediaFolder, pastedImagesFolder, linkedMediaFolder, generatedImagesFolder]
    }
    /// Copies of template reference images; not a cache.
    public var templatesFolder: URL { root.appending(path: "templates", directoryHint: .isDirectory) }

    public func templateFolder(for templateID: UUID) -> URL {
        templatesFolder.appending(path: TemplateFiles.folderName(for: templateID), directoryHint: .isDirectory)
    }

    /// Creates the root, `sources/` and `cache/presets/`.
    public func prepareDirectories() throws {
        for folder in [root, sourcesFolder, presetCacheFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// The default output folder, created on first use.
    public func outputFolder() throws -> URL {
        try FileManager.default.createDirectory(at: defaultOutputFolder, withIntermediateDirectories: true)
        return defaultOutputFolder
    }

    /// Removes `sources/`, `cache/` and the downloaded inputs only; the store, the results and the template images
    /// are kept, and so are the files in `kept`, such as the ones the Create draft points at, with the folders that
    /// hold them. Call it only while no job is active: queued jobs read these files.
    public func clearCache(keeping kept: Set<URL> = []) throws {
        let keptPaths = Set(kept.filter(\.isFileURL).map(Self.comparablePath))
        for folder in [sourcesFolder, cacheFolder] + downloadedInputFolders
        where FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try Self.remove(folder, keeping: keptPaths)
        }
    }

    /// Removes `item` whole when none of `kept` is it or inside it; otherwise everything in it except those.
    private static func remove(_ item: URL, keeping kept: Set<String>) throws {
        let path = comparablePath(item)
        guard !kept.contains(path) else { return }
        guard kept.contains(where: { $0.hasPrefix(path + "/") }) else {
            try FileManager.default.removeItem(at: item)
            return
        }
        for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
            try remove(child, keeping: kept)
        }
    }

    /// `url`'s path with symbolic links resolved and no trailing slash, so a file and its folder compare as paths.
    private static func comparablePath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: Templates

    /// Copies `sources`, which must be readable, into the template's own folder and returns the copies in order.
    /// Nothing is left behind when a copy fails.
    public func copyTemplateImages(_ sources: [URL], templateID: UUID) throws -> [URL] {
        let folder = templateFolder(for: templateID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try zip(sources, TemplateFiles.fileNames(for: sources)).map { source, name in
                let copy = folder.appending(path: name, directoryHint: .notDirectory)
                try fileManager.copyItem(at: source, to: copy)
                return copy
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// Deletes a template's copied images.
    public func removeTemplateImages(templateID: UUID) throws {
        let folder = templateFolder(for: templateID)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Deletes image folders of templates that no longer exist.
    public func pruneTemplateImages(keeping templateIDs: Set<UUID>) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: templatesFolder.path(percentEncoded: false)) else { return }
        let folders = try fileManager.contentsOfDirectory(
            at: templatesFolder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for name in TemplateFiles.orphanedFolders(folders.map(\.lastPathComponent), keeping: templateIDs) {
            try fileManager.removeItem(at: templatesFolder.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// Moves a library file to the Trash instead of deleting it.
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: Custom output folder

    /// A security-scoped bookmark for a folder the user picked, to keep access across launches.
    public static func bookmarkData(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark from `bookmarkData(for:)`. When it is stale, `refreshedData` holds a new one to save.
    /// The caller brackets file access with `start/stopAccessingSecurityScopedResource()`.
    public static func resolveBookmark(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard isStale else { return ResolvedBookmark(url: url, refreshedData: nil) }

        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        let refreshed = try bookmarkData(for: url)
        return ResolvedBookmark(url: url, refreshedData: refreshed)
    }

    /// Where a bookmarked folder was when the bookmark was made or last refreshed, read without resolving it, so
    /// it works while the folder's drive is unplugged.
    public static func bookmarkedURL(_ data: Data) -> URL? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path.map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
    }
}

public struct ResolvedBookmark: Sendable, Hashable {
    public let url: URL
    /// Non-nil when the stored bookmark was stale and should be replaced with this one.
    public let refreshedData: Data?

    public init(url: URL, refreshedData: Data?) {
        self.url = url
        self.refreshedData = refreshedData
    }
}
