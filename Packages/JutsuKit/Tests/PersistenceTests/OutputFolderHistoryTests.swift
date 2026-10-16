import Foundation
import Persistence
import Testing

@Suite struct OutputFolderHistoryTests {
    struct Unresolvable: Error {}

    let folderA = URL(filePath: "/Volumes/Drive/Renders A/", directoryHint: .isDirectory)
    let folderB = URL(filePath: "/Users/me/Renders B/", directoryHint: .isDirectory)
    let bookmarkA = Data("a".utf8)
    let bookmarkB = Data("b".utf8)

    /// Resolves bookmarks from a table, like the sandbox does for folders that are still there.
    private func resolver(_ table: [Data: ResolvedBookmark]) -> (Data) throws -> ResolvedBookmark {
        { data in
            guard let resolved = table[data] else { throw Unresolvable() }
            return resolved
        }
    }

    @Test func itemsInFolderAStayResolvableAfterSwitchingToFolderB() {
        let result = folderA.appending(path: "2026-10-14_restyle_1a2b3c4d.mp4")
        var history = OutputFolderHistory()
        // Switching from A to B retires A.
        history.add(.init(url: folderA, bookmark: bookmarkA))

        // The next launch reads it back from defaults and opens it.
        var relaunched = OutputFolderHistory(stored: history.encoded())
        let opened = relaunched.resolve(with: resolver([bookmarkA: ResolvedBookmark(url: folderA, refreshedData: nil)]))

        #expect(opened == [folderA])
        #expect(opened.contains { result.path(percentEncoded: false).hasPrefix($0.path(percentEncoded: false)) })
        #expect(relaunched.prune(relaunched.urls, keeping: [result]).isEmpty)
        #expect(relaunched.folders == [.init(url: folderA, bookmark: bookmarkA)])
    }

    @Test func aStaleBookmarkIsReplacedAndAMovedFolderFollowed() {
        let moved = URL(filePath: "/Volumes/Drive/Renders A (old)/", directoryHint: .isDirectory)
        let refreshed = Data("a2".utf8)
        var history = OutputFolderHistory(folders: [.init(url: folderA, bookmark: bookmarkA)])

        let opened = history.resolve(
            with: resolver([bookmarkA: ResolvedBookmark(url: moved, refreshedData: refreshed)]))

        #expect(opened == [moved])
        #expect(history.folders == [.init(url: moved, bookmark: refreshed)])
    }

    @Test func aFolderThatDoesNotResolveIsKeptForTheNextLaunch() {
        var history = OutputFolderHistory(folders: [.init(url: folderA, bookmark: bookmarkA)])

        #expect(history.resolve(with: resolver([:])).isEmpty)
        #expect(history.folders == [.init(url: folderA, bookmark: bookmarkA)])
    }

    @Test func foldersNoResultUsesAreDropped() {
        var history = OutputFolderHistory(folders: [
            .init(url: folderA, bookmark: bookmarkA), .init(url: folderB, bookmark: bookmarkB),
        ])
        let partialDownload = folderB.appending(path: "nested", directoryHint: .isDirectory)
        // A sibling whose name starts like folder A's is not inside it.
        let sibling = URL(filePath: "/Volumes/Drive/Renders A2/result.mp4")

        let dropped = history.prune(history.urls, keeping: [sibling, partialDownload])

        #expect(dropped.map(OutputFolderHistory.path(of:)) == ["/Volumes/Drive/Renders A"])
        #expect(history.folders == [.init(url: folderB, bookmark: bookmarkB)])
    }

    @Test func aFolderAddedAfterTheJobsWereReadIsNotDropped() {
        var history = OutputFolderHistory(folders: [.init(url: folderA, bookmark: bookmarkA)])
        let candidates = history.urls
        history.add(.init(url: folderB, bookmark: bookmarkB))

        _ = history.prune(candidates, keeping: [])

        #expect(history.folders == [.init(url: folderB, bookmark: bookmarkB)])
    }

    @Test func switchingBackToAFolderRemovesItFromTheHistory() {
        var history = OutputFolderHistory()
        history.add(.init(url: folderA, bookmark: bookmarkA))
        history.add(.init(url: folderA, bookmark: Data("a2".utf8)))
        #expect(history.folders.count == 1)

        let removedA = history.remove(URL(filePath: "/Volumes/Drive/Renders A"))
        let removedB = history.remove(folderB)

        #expect(removedA)
        #expect(!removedB)
        #expect(history.folders.isEmpty)
    }

    @Test func nothingOrGarbageStoredMeansNoEarlierFolders() {
        #expect(OutputFolderHistory(stored: nil).folders.isEmpty)
        #expect(OutputFolderHistory(stored: Data("not json".utf8)).folders.isEmpty)
    }
}
