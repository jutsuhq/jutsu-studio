import Foundation
import JutsuCore
import Testing

@testable import Presentation

private func file(_ name: String) -> URL { URL(fileURLWithPath: "/home/me/Desktop/\(name)") }

@Suite struct OpenedFileKindTests {
    @Test(arguments: ["clip.mov", "clip.MP4", "clip.m4v", "clip.webm"])
    func videosByExtension(_ name: String) {
        #expect(OpenedFileKind(file(name)) == .video)
    }

    @Test(arguments: ["shot.png", "shot.JPG", "shot.heic", "shot.webp"])
    func imagesByExtension(_ name: String) {
        #expect(OpenedFileKind(file(name)) == .image)
    }

    @Test func unknownFilesAreUnsupported() {
        #expect(OpenedFileKind(file("notes.pdf")) == .unsupported)
        #expect(OpenedFileKind(file("README")) == .unsupported)
    }

    @Test func remoteURLsAreUnsupported() throws {
        let url = try #require(URL(string: "https://example.com/clip.mov"))
        #expect(OpenedFileKind(url) == .unsupported)
    }

    @Test func typeConformanceCoversUnknownExtensions() {
        let conforms: (URL, String) -> Bool = { url, type in
            (url.pathExtension == "dv" && type == "public.movie")
                || (url.pathExtension == "raw" && type == "public.image")
        }
        #expect(OpenedFileKind(file("tape.dv"), conformsTo: conforms) == .video)
        #expect(OpenedFileKind(file("frame.raw"), conformsTo: conforms) == .image)
        #expect(OpenedFileKind(file("notes.pdf"), conformsTo: conforms) == .unsupported)
    }
}

@Suite struct OpenRequestTests {
    @Test func sortsAMix() {
        let request = OpenRequest([file("a.png"), file("clip.mov"), file("notes.pdf"), file("b.jpg")])
        #expect(request.video == file("clip.mov"))
        #expect(request.images == [file("a.png"), file("b.jpg")])
        #expect(request.unsupported == [file("notes.pdf")])
    }

    @Test func lastVideoWins() {
        #expect(OpenRequest([file("one.mov"), file("two.mp4")]).video == file("two.mp4"))
    }

    @Test func repeatedImagesCountOnce() {
        #expect(OpenRequest([file("a.png"), file("a.png")]).images == [file("a.png")])
    }

    @Test func mergeKeepsOpeningOrder() {
        var request = OpenRequest([file("one.mov"), file("a.png")])
        request.merge(OpenRequest([file("b.png"), file("a.png")]))
        #expect(request.video == file("one.mov"))
        #expect(request.images == [file("a.png"), file("b.png")])
        request.merge(OpenRequest([file("two.mov")]))
        #expect(request.video == file("two.mov"))
    }

    @Test func unsupportedMessageNamesASingleFile() {
        #expect(OpenRequest([file("clip.mov")]).unsupportedMessage == nil)
        #expect(OpenRequest([file("notes.pdf")]).unsupportedMessage?.title == "Can't open “notes.pdf”")
        #expect(OpenRequest([file("a.pdf"), file("b.zip")]).unsupportedMessage?.title == "Can't open 2 files")
    }
}

@Suite struct PendingOpensTests {
    @Test func holdsRequestsUntilTaken() {
        var pending = PendingOpens()
        pending.add(OpenRequest([file("clip.mov")]))
        pending.add(OpenRequest([file("a.png")]))
        #expect(!pending.isEmpty)
        let request = pending.take()
        #expect(request?.video == file("clip.mov"))
        #expect(request?.images == [file("a.png")])
        #expect(pending.isEmpty)
        #expect(pending.take() == nil)
    }

    @Test func ignoresEmptyRequests() {
        var pending = PendingOpens()
        pending.add(OpenRequest([]))
        #expect(pending.isEmpty)
    }
}

@Suite struct OpenedReferencesTests {
    @Test func addsWithinTheLimit() {
        var form = CreateForm(mode: .motionTransfer)
        let message = form.addOpenedReferences(CreateFixture.references((0..<3).map(CreateFixture.image)))
        #expect(message == nil)
        #expect(form.references.count == 3)
    }

    @Test func saysHowManyDidNotFit() {
        var form = CreateForm(mode: .restyle)
        let message = form.addOpenedReferences(CreateFixture.references((0..<7).map(CreateFixture.image)))
        #expect(form.references.count == 5)
        #expect(message?.title == "2 images weren't added")
        #expect(message?.message == "Restyle takes up to 5 reference images.")
    }

    @Test func skipsImagesAlreadyAddedSilently() {
        var form = CreateForm(mode: .motionTransfer)
        let images = CreateFixture.references([CreateFixture.image(0)])
        form.addReferences(images)
        #expect(form.addOpenedReferences(images) == nil)
        #expect(form.references.count == 1)
    }
}
