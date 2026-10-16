import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct CreateDraftReplacementTests {
    @Test func aFreshFormHasNoInputs() {
        var form = CreateForm(mode: .restyle, resolution: .p1080)
        form.prompt = "  \n"
        #expect(!form.hasInputs)
        form.prompt = "neon"
        #expect(form.hasInputs)
        #expect(CreateFixture.ready().hasInputs)
    }

    @Test func fillingEmptyInputsDropsNothing() {
        var previous = CreateForm()
        previous.setSource(CreateFixture.video())
        var replaced = previous
        replaced.prompt = "Image 1 dances"
        replaced.addReferences(CreateFixture.references([CreateFixture.image(1)]))
        #expect(!replaced.dropsInputs(of: previous))
    }

    @Test func eachReplacedInputCounts() {
        let previous = CreateFixture.ready()
        var prompt = previous
        prompt.prompt = "something else"
        var source = previous
        source.setSource(CreateFixture.video(name: "other.mp4"))
        var range = previous
        range.setEnd(5)
        var images = previous
        images.removeReference(at: 0)
        var withPrompt = CreateFixture.ready()
        withPrompt.prompt = "keep me"
        var promptCleared = withPrompt
        promptCleared.prompt = ""

        #expect(prompt.dropsInputs(of: withPrompt))
        #expect(source.dropsInputs(of: previous))
        #expect(range.dropsInputs(of: previous))
        #expect(images.dropsInputs(of: previous))
        #expect(promptCleared.dropsInputs(of: withPrompt))
        #expect(!previous.dropsInputs(of: previous))
    }

    @Test func undoIsOfferedOnlyForEditedInputsThatAreLost() {
        let edited = CreateFixture.ready()
        var loaded = edited
        loaded.load(JobSpec(mode: .restyle, source: nil, prompt: "rain", resolution: .p720), source: nil)

        let replacement = DraftReplacement(previous: edited, replaced: loaded, untouched: nil)
        #expect(replacement?.previous == edited)
        // The draft is what the last replacement left: the user hadn't touched it.
        #expect(DraftReplacement(previous: edited, replaced: loaded, untouched: edited) == nil)
        // Nothing to lose.
        #expect(DraftReplacement(previous: CreateForm(), replaced: loaded, untouched: nil) == nil)
    }
}

@Suite struct CreateDraftStoreTests {
    private func store() -> (CreateDraftStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CreateDraft-\(UUID().uuidString)")
        return (CreateDraftStore(fileURL: folder.appendingPathComponent("create-draft.json")), folder)
    }

    private func videoForm() -> CreateForm {
        var form = CreateFixture.ready()
        let video = SourceVideo(
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4"), duration: 14.2,
            pixelSize: PixelSize(width: 1920, height: 1080),
            codec: "avc1", fileSize: 1, bookmark: Data([7, 8]))
        form.setSource(video)
        form.setEnd(9)
        form.prompt = "Image 1 dances"
        form.audio = .fadeOut
        form.draftLength = .firstFiveSeconds
        return form
    }

    private func imageForm() -> ImageDraft {
        ImageDraft(
            prompt: "a knight in silver armor", modelID: "soul", chosenAspectRatio: "16:9", count: 4,
            inputImage: LocalImage(fileURL: CreateFixture.image(3)))
    }

    @Test func bothDraftsSurviveARelaunch() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.save(CreateDraftStore.Drafts(video: videoForm(), image: imageForm(), kind: .image))

        let reopened = CreateDraftStore(fileURL: store.fileURL)

        let loaded = try #require(reopened.load())
        #expect(loaded.video == videoForm())
        #expect(loaded.image == imageForm())
        #expect(loaded.kind == .image)
    }

    @Test func savingOneSideKeepsTheOther() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.save(CreateDraftStore.Drafts(video: videoForm(), image: imageForm(), kind: .video))

        var loaded = try #require(store.load())
        loaded.video?.prompt = "changed"
        loaded.kind = .image
        try store.save(loaded)

        let again = try #require(store.load())
        #expect(again.video?.prompt == "changed")
        #expect(again.image == imageForm())
        #expect(again.kind == .image)
    }

    @Test func missingOrForeignFileGivesNothing() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(store.load() == nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "video": null}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test func aV1FileLoadsAsTheVideoDraft() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let form = videoForm()
        struct V1: Codable { var version: Int; var form: CreateForm }
        try JSONEncoder().encode(V1(version: 1, form: form)).write(to: store.fileURL)

        let loaded = try #require(store.load())
        #expect(loaded.video == form)
        #expect(loaded.image == nil)
        #expect(loaded.kind == .video)
    }

    @Test func theFirstV2SaveBacksUpTheV1File() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        struct V1: Codable { var version: Int; var form: CreateForm }
        let v1 = try JSONEncoder().encode(V1(version: 1, form: videoForm()))
        try v1.write(to: store.fileURL)

        try store.save(CreateDraftStore.Drafts(video: videoForm(), image: imageForm(), kind: .image))

        #expect(try Data(contentsOf: store.backupURL) == v1)
        let loaded = try #require(store.load())
        #expect(loaded.image == imageForm())

        // A v2 file needs no backup: saving again leaves the v1 copy alone.
        try store.save(CreateDraftStore.Drafts(video: videoForm(), kind: .video))
        #expect(try Data(contentsOf: store.backupURL) == v1)
    }

    @Test func restoreDropsFilesThatAreGoneAndFollowsMovedOnes() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        var form = CreateFixture.ready()
        form.setEnd(8)
        form.addReferences(CreateFixture.references([CreateFixture.image(2)]))
        let remote = LocalImage(fileURL: try #require(URL(string: "https://cdn.example/ref.png")))
        form.addReferences([remote])
        let image = ImageDraft(prompt: "knight", inputImage: LocalImage(fileURL: CreateFixture.image(3)))
        try store.save(CreateDraftStore.Drafts(video: form, image: image, kind: .image))

        let moved = URL(fileURLWithPath: "/tmp/moved2.png")
        let movedInput = URL(fileURLWithPath: "/tmp/moved3.png")
        let restored = store.restore { file in
            switch file.fileURL {
            case CreateFixture.image(1): nil
            case CreateFixture.image(2): LocalImage(fileURL: moved, bookmark: Data([1]))
            case CreateFixture.image(3): LocalImage(fileURL: movedInput, bookmark: Data([2]))
            default: file
            }
        }

        let video = try #require(restored.video)
        #expect(video.references == [LocalImage(fileURL: moved, bookmark: Data([1])), remote])
        #expect(video.source == form.source)
        #expect(video.range == 0...8)
        #expect(
            restored.image
                == ImageDraft(prompt: "knight", inputImage: LocalImage(fileURL: movedInput, bookmark: Data([2]))))
        #expect(restored.kind == .image)
    }

    @Test func localFilesAreEveryFileTheFormPointsAtButNotTheAccountsMedia() throws {
        var form = CreateFixture.ready()
        form.references.append(LocalImage(fileURL: try #require(URL(string: "https://cdn.example/ref.png"))))
        form.batch.characterSets = [[LocalImage(fileURL: CreateFixture.image(5))]]
        form.frames.end = LocalImage(fileURL: CreateFixture.image(6))
        let source = try #require(form.source?.fileURL)

        #expect(
            form.localFiles
                == [source, CreateFixture.image(1), CreateFixture.image(5), CreateFixture.image(6)])
        #expect(CreateForm().localFiles.isEmpty)
    }

    @Test func aGoneSourceIsDroppedWithItsRanges() throws {
        var form = CreateFixture.ready()
        form.setEnd(8)
        let reopened = form.reopeningFiles { $0.fileURL == form.source?.fileURL ? nil : $0 }
        #expect(reopened.source == nil)
        #expect(reopened.ranges == [0...0])
        #expect(reopened.references == form.references)
    }

    @Test func aDraftWithNothingLeftRestoresAsFreshButKeepsTheKind() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        var form = CreateForm(mode: .objectSwap)
        form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
        let image = ImageDraft(prompt: "knight", chosenAspectRatio: "16:9")
        try store.save(CreateDraftStore.Drafts(video: form, image: image, kind: .image))

        let dropped = store.restore { _ in nil }
        #expect(dropped.video == nil)
        // The prompt stays an input: only the unreadable file is dropped.
        #expect(dropped.image == ImageDraft(prompt: "knight", chosenAspectRatio: "16:9"))
        #expect(dropped.kind == .image)

        let kept = store.restore { $0 }
        #expect(kept.video == form)
        #expect(kept.image == image)
        #expect(kept.kind == .image)
    }

    @Test func aSideWithSettingsOnlyRestoresAsFresh() throws {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let form = CreateForm(mode: .objectSwap)
        let image = ImageDraft(chosenAspectRatio: "16:9")
        try store.save(CreateDraftStore.Drafts(video: form, image: image, kind: .image))

        let restored = store.restore { $0 }
        #expect(restored.video == nil)
        #expect(restored.image == nil)
        #expect(restored.kind == .image)
    }

    @Test func restoreWithoutAFileIsEmptyOnTheVideoSide() {
        let (store, folder) = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restored = store.restore { $0 }
        #expect(restored.video == nil)
        #expect(restored.image == nil)
        #expect(restored.kind == .video)
    }
}

@Suite struct ImageDraftTests {
    @Test func aFreshDraftHasNoInputs() {
        #expect(!ImageDraft().hasInputs)
        #expect(!ImageDraft(modelID: "soul", chosenAspectRatio: "16:9", count: 4).hasInputs)
        #expect(ImageDraft(prompt: "  \n").hasInputs == false)
        #expect(ImageDraft(prompt: "knight").hasInputs)
        #expect(ImageDraft(inputImage: LocalImage(fileURL: CreateFixture.image(1))).hasInputs)
    }

    @Test func localFilesAreTheInputButNotTheAccountsMedia() throws {
        #expect(ImageDraft().localFiles.isEmpty)
        #expect(
            ImageDraft(inputImage: LocalImage(fileURL: CreateFixture.image(1))).localFiles
                == [CreateFixture.image(1)])
        let remote = LocalImage(fileURL: try #require(URL(string: "https://cdn.example/in.png")))
        #expect(ImageDraft(inputImage: remote).localFiles.isEmpty)
    }
}
