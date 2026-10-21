import Foundation
import Testing

@testable import JutsuCore

@Suite struct MediaLinkParseTests {
    @Test func takesOneHTTPSLinkWithSpacesAround() throws {
        let link = try MediaLink.parse("  https://cdn.example.com/clip.mp4?sig=1\n")
        #expect(link.absoluteString == "https://cdn.example.com/clip.mp4?sig=1")
    }

    @Test func refusesPlainHTTPWithItsOwnReason() {
        #expect(throws: MediaLinkError.notHTTPS) { try MediaLink.parse("http://cdn.example.com/clip.mp4") }
    }

    @Test(arguments: [
        "", "clip.mp4", "file:///home/me/clip.mp4", "ftp://example.com/a.mp4", "https://", "https:///clip.mp4",
        "https://example.com/a.mp4 https://example.com/b.mp4", "see https://example.com/a.mp4",
    ])
    func refusesWhatIsNotAWebLink(text: String) {
        #expect(throws: MediaLinkError.notALink) { try MediaLink.parse(text) }
    }
}

@Suite struct MediaLinkClassifyTests {
    let page = URL(string: "https://www.youtube.com/watch?v=abc")!
    let mov = URL(string: "https://storage.example.com/take.MOV")!

    @Test func knownTypesNameTheKindAndExtension() throws {
        let video = try MediaLink.classify(contentType: "video/mp4", url: page)
        let image = try MediaLink.classify(contentType: "image/jpeg; charset=binary", url: page)
        #expect(video == (.video, "mp4"))
        #expect(image == (.image, "jpg"))
    }

    @Test func aGenericOrMissingTypeFallsBackToTheLinksExtension() throws {
        #expect(try MediaLink.classify(contentType: "application/octet-stream", url: mov) == (.video, "mov"))
        #expect(try MediaLink.classify(contentType: nil, url: mov) == (.video, "mov"))
        #expect(try MediaLink.classify(contentType: "video/x-unknown", url: mov) == (.video, "mov"))
    }

    @Test func aWebPageIsNotMediaEvenWhenTheLinkLooksLikeAFile() {
        #expect(throws: MediaLinkError.notMedia(contentType: "text/html")) {
            try MediaLink.classify(contentType: "text/html; charset=utf-8", url: page)
        }
        #expect(throws: MediaLinkError.notMedia(contentType: "text/html")) {
            try MediaLink.classify(contentType: "text/html", url: mov)
        }
        #expect(throws: MediaLinkError.notMedia(contentType: "application/octet-stream")) {
            try MediaLink.classify(contentType: "application/octet-stream", url: page)
        }
        #expect(throws: MediaLinkError.notMedia(contentType: nil)) {
            try MediaLink.classify(contentType: nil, url: page)
        }
        #expect(throws: MediaLinkError.notMedia(contentType: "image/x-unknown")) {
            try MediaLink.classify(contentType: "image/x-unknown", url: mov)
        }
    }

    @Test func aPictureToShowTakesAnyImageTypeButNoPage() throws {
        try MediaLink.checkImage(contentType: "image/avif")
        try MediaLink.checkImage(contentType: "application/octet-stream")
        try MediaLink.checkImage(contentType: nil)
        #expect(throws: MediaLinkError.notMedia(contentType: "text/html")) {
            try MediaLink.checkImage(contentType: "text/html; charset=utf-8")
        }
        #expect(throws: MediaLinkError.notMedia(contentType: "video/mp4")) {
            try MediaLink.checkImage(contentType: "video/mp4")
        }
    }

    @Test func theFileIsNamedAfterTheLink() throws {
        #expect(MediaLink.baseName(of: mov) == "take")
        #expect(MediaLink.baseName(of: try #require(URL(string: "https://example.com/"))) == "example.com")
    }
}

@Suite struct RemoteOriginTests {
    let origin = URL(string: "https://cdn.example.com/clip.mp4")!

    func clip(
        _ range: ClosedRange<TimeInterval>, file: String = "clip.mp4", origin: URL? = nil,
        size: PixelSize = PixelSize(width: 1280, height: 720), allowsUpscale: Bool = false
    ) -> SourceClip {
        SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/links/\(file)"), duration: 12, pixelSize: size, range: range,
            allowsUpscale: allowsUpscale, remoteOrigin: origin)
    }

    @Test func theWholeUntouchedClipIsSentByItsLink() {
        #expect(clip(0...12, origin: origin).linkableOrigin == origin)
    }

    @Test func aTrimmedClipIsUploaded() {
        #expect(clip(2...12, origin: origin).linkableOrigin == nil)
        #expect(clip(0...5, origin: origin).linkableOrigin == nil)
    }

    @Test func anUpscaledOrConvertedClipIsUploaded() {
        let small = PixelSize(width: 480, height: 360)
        #expect(clip(0...12, origin: origin, size: small, allowsUpscale: true).linkableOrigin == nil)
        #expect(clip(0...12, file: "clip.mov", origin: origin).linkableOrigin == nil)
    }

    @Test func aPickedFileHasNoLink() {
        #expect(clip(0...12).linkableOrigin == nil)
    }

    @Test func imagesOfTypesTheAPITakesAreSentByTheirLink() {
        let png = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/links/face.png"), remoteOrigin: origin)
        let heic = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/links/face.heic"), remoteOrigin: origin)
        #expect(png.linkableOrigin == origin)
        #expect(heic.linkableOrigin == nil)
        #expect(LocalImage(fileURL: URL(fileURLWithPath: "/tmp/face.png")).linkableOrigin == nil)
    }

    @Test func recordsStoredBeforeLinksDecodeWithoutOne() throws {
        let json = Data(
            """
            {"mode": "motionTransfer", "prompt": "", "resolution": "720p", "isDraft": false,
             "source": {"fileURL": "file:///tmp/a.mp4", "duration": 8, "pixelSize": {"width": 1280, "height": 720},
                        "range": [0, 8], "allowsUpscale": false},
             "references": [{"fileURL": "file:///tmp/b.png"}]}
            """.utf8)

        let spec = try JSONDecoder().decode(JobSpec.self, from: json)

        #expect(spec.source?.remoteOrigin == nil)
        #expect(spec.references.first?.remoteOrigin == nil)
    }

    @Test func theLinkSurvivesEncoding() throws {
        let spec = JobSpec(
            mode: .motionTransfer, source: clip(0...12, origin: origin),
            references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/b.png"), remoteOrigin: origin)],
            resolution: .p720)

        let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec))

        #expect(decoded == spec)
        #expect(decoded.source?.remoteOrigin == origin)
    }
}
