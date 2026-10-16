import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct PastedLinkTests {
    let link = URL(string: "https://cdn.example.org/clip.mp4")!

    @Test func aCopiedLinkIsDownloaded() {
        #expect(PastedInput(fileURLs: [], hasImage: false, links: [link]) == .link(link))
        #expect(PastedInput(fileURLs: [], hasImage: false, text: " https://cdn.example.org/clip.mp4\n") == .link(link))
    }

    @Test func filesAndImageDataWinOverALink() {
        let file = URL(fileURLWithPath: "/tmp/a.mov")
        #expect(PastedInput(fileURLs: [file], hasImage: false, links: [link]) == .files([file]))
        #expect(PastedInput(fileURLs: [], hasImage: true, links: [link]) == .image)
    }

    @Test func otherTextIsNotALink() throws {
        let insecure = try #require(URL(string: "http://cdn.example.org/clip.mp4"))
        #expect(PastedInput(fileURLs: [], hasImage: false, links: [insecure]) == nil)
        #expect(PastedInput(fileURLs: [], hasImage: false, text: "a prompt about https://x.org") == nil)
        #expect(PastedInput(fileURLs: [], hasImage: false, text: "") == nil)
    }
}

@Suite struct LinkedSourceFormTests {
    let origin = URL(string: "https://cdn.example.org/clip.mp4")!

    func linkedForm() -> CreateForm {
        var video = CreateFixture.video(duration: 12)
        video.remoteOrigin = origin
        var form = CreateForm(mode: .motionTransfer, resolution: .p720)
        form.setSource(video)
        form.addReferences([LocalImage(fileURL: CreateFixture.image(1), remoteOrigin: origin)])
        return form
    }

    @Test func theJobCarriesTheLinkAndSendsAWholeClipByIt() throws {
        let spec = try #require(linkedForm().makeSpecs(isDraft: false).first)

        #expect(spec.source?.remoteOrigin == origin)
        #expect(spec.source?.linkableOrigin == origin)
        #expect(spec.references.first?.remoteOrigin == origin)
    }

    @Test func aDraftOfTheFirstSecondsIsTrimmedSoItUploads() throws {
        var form = linkedForm()
        form.draftLength = .firstFiveSeconds

        let draft = try #require(form.makeSpecs(isDraft: true).first)

        #expect(draft.source?.remoteOrigin == origin)
        #expect(draft.source?.linkableOrigin == nil)
    }

    @Test func editingInputsKeepsTheLink() throws {
        let spec = try #require(linkedForm().makeSpecs(isDraft: false).first)
        var form = CreateForm()

        form.load(spec, source: CreateFixture.video(duration: 12))

        #expect(form.source?.remoteOrigin == origin)
        #expect(form.makeSpecs(isDraft: false).first?.source?.linkableOrigin == origin)
    }

    @Test func aSavedDraftKeepsTheLink() throws {
        let store = CreateDraftStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }

        try store.save(CreateDraftStore.Drafts(video: linkedForm()))

        #expect(store.load()?.video == linkedForm())
    }

    @Test func aSourceSavedBeforeLinksDecodesWithoutOne() throws {
        let json = Data(
            """
            {"fileURL": "file:///tmp/a.mp4", "duration": 8, "pixelSize": {"width": 1280, "height": 720},
             "codec": "avc1", "fileSize": 100}
            """.utf8)

        #expect(try JSONDecoder().decode(SourceVideo.self, from: json).remoteOrigin == nil)
    }
}

@Suite struct LinkMessageTests {
    @Test func aWebPageSaysToUseADirectLink() {
        let message = UserMessage(MediaLinkError.notMedia(contentType: "text/html"))
        #expect(message.title == "This link isn't a video or an image")
        #expect(message.message.contains("YouTube"))
    }

    @Test func aRefusedDownloadSaysToSaveTheFileInABrowser() {
        let refused = UserMessage(MediaLinkError.unavailable(status: 403))
        #expect(refused.message.contains("drop it on the window"))
        #expect(UserMessage(MediaLinkError.unavailable(status: 404)).message.contains("opens in a browser"))
    }

    @Test func linkErrorsGetTheirOwnMessageThroughTheGenericPath() throws {
        let message = try #require(UserMessage(MediaLinkError.notHTTPS as any Error))
        #expect(message == UserMessage(MediaLinkError.notHTTPS))
    }

    @Test func progressNamesTheHostAndWholePercent() throws {
        let link = try #require(URL(string: "https://cdn.example.org/clip.mp4"))
        #expect(LinkDownload(link: link, expected: nil).text == "Downloading from cdn.example.org…")
        #expect(
            LinkDownload(link: link, expected: nil, fraction: 0.426).text == "Downloading from cdn.example.org… 42%")
    }

    @Test func aPastedDownloadShowsUnderTheSourceUnlessAnImageWasAskedFor() throws {
        let link = try #require(URL(string: "https://cdn.example.org/a"))
        #expect(LinkDownload(link: link, expected: nil).shows(in: .video))
        #expect(LinkDownload(link: link, expected: .image).shows(in: .image))
        #expect(!LinkDownload(link: link, expected: .image).shows(in: .video))
    }
}
