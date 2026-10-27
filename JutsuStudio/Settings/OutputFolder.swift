import Foundation
import JutsuCore
import Observation
import Persistence
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Settings")

/// Where results download: the folder picked in Settings, kept as a security-scoped bookmark, or the
/// default `~/Movies/Jutsu Studio`. Holds the picked folder's scoped access open while it is in use, and that of
/// every earlier picked folder that still holds results, so the library can read them for the whole launch.
@MainActor
@Observable
final class OutputFolder {
    private(set) var url: URL
    private(set) var isCustom = false

    @ObservationIgnored private let layout: FileLayout
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var history: OutputFolderHistory
    /// Earlier folders with access started, by `OutputFolderHistory.path(of:)`.
    @ObservationIgnored private var previousAccess: [String: URL] = [:]

    init(layout: FileLayout, defaults: UserDefaults) {
        self.layout = layout
        self.defaults = defaults
        url = layout.defaultOutputFolder
        history = OutputFolderHistory(stored: defaults.data(forKey: AppSettings.previousOutputFoldersKey))
        for folder in history.resolve(with: FileLayout.resolveBookmark) {
            startAccessingPrevious(folder)
        }
        saveHistory()
        if let bookmark = AppSettings.outputFolderBookmark(in: defaults) {
            do {
                try open(bookmark)
                return
            } catch {
                // Kept in defaults: an unplugged drive may be back on the next launch.
                logger.error("Can't open the output folder: \(String(describing: error), privacy: .private)")
            }
        }
        url = Self.prepareDefault(layout)
    }

    /// Switches to `folder`, or back to the default with `nil`. Throws when the folder can't be bookmarked.
    /// The folder switched away from keeps its access: its results stay readable and a download into it finishes.
    func use(_ folder: URL?) throws {
        guard let folder else {
            retireCurrent()
            defaults.removeObject(forKey: AppSettings.outputFolderBookmarkKey)
            url = Self.prepareDefault(layout)
            isCustom = false
            return
        }
        // The picker's URL grants access only while it is held; the bookmark has to be made inside it.
        let isAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { folder.stopAccessingSecurityScopedResource() }
        }
        let bookmark = try FileLayout.bookmarkData(for: folder)
        let resolved = try FileLayout.resolveBookmark(bookmark)
        retireCurrent()
        use(resolved, bookmark: bookmark)
    }

    /// Forgets the earlier folders that hold none of `files` and gives up their access. Only `candidates`, taken
    /// from `previousFolders` before `files` were read, are dropped.
    func forgetPreviousFolders(_ candidates: [URL], keeping files: [URL]) {
        let dropped = history.prune(candidates, keeping: files)
        guard !dropped.isEmpty else { return }
        for folder in dropped {
            previousAccess.removeValue(forKey: OutputFolderHistory.path(of: folder))?
                .stopAccessingSecurityScopedResource()
        }
        saveHistory()
    }

    var previousFolders: [URL] { history.urls }

    /// Whether `file` is in the output folder or one used before: a file the app wrote and keeps, which Delete from
    /// Library may trash with the item. Files elsewhere are the person's own.
    func owns(_ file: URL) -> Bool {
        ([url] + previousFolders).contains {
            OutputFolderHistory.folder(at: OutputFolderHistory.path(of: $0), contains: file)
        }
    }

    /// The folder of one kind of result inside the current output folder.
    func url(of kind: OutputSubfolder) -> URL {
        kind.url(in: url)
    }

    private func open(_ bookmark: Data) throws {
        use(try FileLayout.resolveBookmark(bookmark), bookmark: bookmark)
    }

    private func use(_ resolved: ResolvedBookmark, bookmark: Data) {
        defaults.set(resolved.refreshedData ?? bookmark, forKey: AppSettings.outputFolderBookmarkKey)
        // The current folder is opened below; a duplicate entry would be pruned while it gains results.
        if history.remove(resolved.url) {
            previousAccess.removeValue(forKey: OutputFolderHistory.path(of: resolved.url))?
                .stopAccessingSecurityScopedResource()
            saveHistory()
        }
        if resolved.url.startAccessingSecurityScopedResource() { scopedURL = resolved.url }
        url = resolved.url
        isCustom = true
    }

    /// Moves the stored custom folder, reachable or not, into the history, keeping its access open.
    private func retireCurrent() {
        if let scopedURL {
            previousAccess[OutputFolderHistory.path(of: scopedURL)] = scopedURL
            self.scopedURL = nil
        }
        guard let bookmark = AppSettings.outputFolderBookmark(in: defaults),
            let folder = isCustom ? url : FileLayout.bookmarkedURL(bookmark)
        else { return }
        history.add(OutputFolderHistory.Folder(url: folder, bookmark: bookmark))
        saveHistory()
    }

    private func startAccessingPrevious(_ folder: URL) {
        let path = OutputFolderHistory.path(of: folder)
        guard previousAccess[path] == nil, folder.startAccessingSecurityScopedResource() else { return }
        previousAccess[path] = folder
    }

    private func saveHistory() {
        if history.folders.isEmpty {
            defaults.removeObject(forKey: AppSettings.previousOutputFoldersKey)
        } else {
            defaults.set(history.encoded(), forKey: AppSettings.previousOutputFoldersKey)
        }
    }

    private static func prepareDefault(_ layout: FileLayout) -> URL {
        do {
            return try layout.outputFolder()
        } catch {
            logger.error("Can't create the output folder: \(String(describing: error), privacy: .private)")
            return layout.defaultOutputFolder
        }
    }
}
