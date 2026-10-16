import Foundation
import JutsuCore
import Persistence
import Testing

@Suite struct FileLayoutTests {
    let temp: URL
    let layout: FileLayout

    init() {
        temp = FileManager.default.temporaryDirectory.appending(path: "PersistenceTests-\(UUID().uuidString)")
        layout = FileLayout(root: temp.appending(path: "support"), defaultOutputFolder: temp.appending(path: "Movies"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func layoutPaths() {
        #expect(layout.storeURL.lastPathComponent == "default.store")
        #expect(layout.sourcesFolder == layout.root.appending(path: "sources", directoryHint: .isDirectory))
        #expect(layout.presetCacheFolder.pathComponents.suffix(2) == ["cache", "presets"])
    }

    @Test func clearCacheRemovesOnlySourcesCacheAndDownloadedInputs() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        try layout.prepareDirectories()
        try Data("store".utf8).write(to: layout.storeURL)
        for folder in layout.downloadedInputFolders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("input".utf8).write(to: folder.appending(path: "input.mp4"))
        }
        try Data("clip".utf8).write(to: layout.sourcesFolder.appending(path: "clip.mp4"))
        try Data("{}".utf8).write(to: layout.presetCacheFolder.appending(path: "catalog.json"))
        let output = try layout.outputFolder()
        try Data("result".utf8).write(to: output.appending(path: "result.mp4"))
        let image = temp.appending(path: "face.png")
        try Data("png".utf8).write(to: image)
        let copies = try layout.copyTemplateImages([image], templateID: UUID())

        try layout.clearCache()
        try layout.clearCache()

        #expect(!exists(layout.sourcesFolder))
        #expect(!exists(layout.cacheFolder))
        #expect(!exists(layout.motionLibraryFolder))
        #expect(!exists(layout.accountMediaFolder))
        #expect(exists(layout.storeURL))
        #expect(exists(output.appending(path: "result.mp4")))
        #expect(copies.allSatisfy { exists($0) })
    }

    @Test func clearCacheKeepsTheFilesItIsToldToKeep() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        try layout.prepareDirectories()
        let pasted = layout.pastedImagesFolder.appending(path: "paste.png")
        let link = layout.linkedMediaFolder.appending(path: "a/clip.mp4")
        let otherLink = layout.linkedMediaFolder.appending(path: "b/clip.mp4")
        let generated = layout.generatedImagesFolder.appending(path: "c/image.png")
        let otherPaste = layout.pastedImagesFolder.appending(path: "old.png")
        for file in [pasted, link, otherLink, generated, otherPaste] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("media".utf8).write(to: file)
        }
        let elsewhere = temp.appending(path: "Desktop/face.png")

        let remote = try #require(URL(string: "https://example.com/a.png"))
        try layout.clearCache(keeping: [pasted, link, elsewhere, remote])

        #expect(exists(pasted))
        #expect(exists(link))
        #expect(!exists(otherPaste))
        #expect(!exists(otherLink.deletingLastPathComponent()))
        #expect(!exists(layout.generatedImagesFolder))
        #expect(!exists(layout.sourcesFolder))
        #expect(!exists(layout.motionLibraryFolder))
    }

    @Test func templateImagesSurviveTheOriginalsAndAreRemovedWithTheTemplate() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let first = temp.appending(path: "a/face.png")
        let second = temp.appending(path: "b/face.png")
        for (url, text) in [(first, "one"), (second, "two")] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let id = UUID()

        let copies = try layout.copyTemplateImages([first, second], templateID: id)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)

        #expect(copies.map(\.lastPathComponent) == ["1-face.png", "2-face.png"])
        #expect(try copies.map { try String(contentsOf: $0, encoding: .utf8) } == ["one", "two"])
        #expect(copies.allSatisfy { $0.deletingLastPathComponent() == layout.templateFolder(for: id) })
        try layout.removeTemplateImages(templateID: id)
        try layout.removeTemplateImages(templateID: id)
        #expect(!exists(layout.templateFolder(for: id)))
    }

    @Test func failedCopyLeavesNoFolder() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        let id = UUID()
        #expect(throws: (any Error).self) {
            try layout.copyTemplateImages([temp.appending(path: "missing.png")], templateID: id)
        }
        #expect(!exists(layout.templateFolder(for: id)))
    }

    @Test func pruneRemovesOnlyFoldersWithoutATemplate() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let image = temp.appending(path: "face.png")
        try Data("png".utf8).write(to: image)
        let kept = UUID()
        let orphan = UUID()
        _ = try layout.copyTemplateImages([image], templateID: kept)
        _ = try layout.copyTemplateImages([image], templateID: orphan)

        try layout.pruneTemplateImages(keeping: [kept])

        #expect(exists(layout.templateFolder(for: kept)))
        #expect(!exists(layout.templateFolder(for: orphan)))
    }

    @Test func outputFolderIsCreatedOnDemand() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(!exists(layout.defaultOutputFolder))
        #expect(try layout.outputFolder() == layout.defaultOutputFolder)
        #expect(exists(layout.defaultOutputFolder))
    }

    @Test func moveToTrashRemovesFileFromItsFolder() throws {
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appending(path: "trash-me.mp4")
        try Data("x".utf8).write(to: file)

        try FileLayout.moveToTrash(file)
        #expect(!exists(file))
    }
}
