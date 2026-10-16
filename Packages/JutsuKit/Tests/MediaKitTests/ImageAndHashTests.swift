import Foundation
import JutsuCore
import MediaKit
import Testing
import UniformTypeIdentifiers

@Suite struct ImagePreparerTests {
    /// A start frame's shape sets the account's frame for a clip from frames, so the size is the one the image shows.
    @Test func imageSizeIsUpright() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))
        let upright = try #require(Fixtures.makeImage(in: directory, width: 480, height: 854, type: .png))
        // Orientation 6: stored landscape, shown turned a quarter.
        let turned = try #require(
            Fixtures.makeImage(in: directory, width: 854, height: 480, type: .jpeg, orientation: 6))

        #expect(await preparer.imageSize(of: LocalImage(fileURL: upright)) == PixelSize(width: 480, height: 854))
        #expect(await preparer.imageSize(of: LocalImage(fileURL: turned)) == PixelSize(width: 480, height: 854))
        let missing = directory.appendingPathComponent("missing.png")
        #expect(await preparer.imageSize(of: LocalImage(fileURL: missing)) == nil)
    }

    @Test func convertsTIFFToJPEG() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(Fixtures.makeImage(in: directory, width: 1200, height: 800, type: .tiff))
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let file = try await preparer.prepareImage(LocalImage(fileURL: url))
        let size = try #require(Fixtures.imageSize(at: file.fileURL))

        #expect(file.contentType == "image/jpeg")
        #expect(size.width == 1200 && size.height == 800)
    }

    @Test func convertsHEICToJPEG() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Some virtualised CI Macs have no HEIC encoder; there is nothing to test without the fixture.
        guard let url = Fixtures.makeImage(in: directory, width: 640, height: 480, type: .heic) else { return }
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let file = try await preparer.prepareImage(LocalImage(fileURL: url))

        #expect(file.contentType == "image/jpeg")
        #expect(file.fileURL.pathExtension == "jpeg")
    }

    @Test func keepsSmallPNGAsIs() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(Fixtures.makeImage(in: directory, width: 300, height: 200, type: .png))
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let file = try await preparer.prepareImage(LocalImage(fileURL: url))
        let sourceHash = try ContentHasher.sha256Hex(ofFileAt: url)

        #expect(file.contentType == "image/png")
        #expect(file.contentHash == sourceHash)
    }

    @Test func aReplacedSourceIsHashedAgain() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(Fixtures.makeImage(in: directory, width: 300, height: 200, type: .png))
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))
        let first = try await preparer.prepareImage(LocalImage(fileURL: url))

        let other = try #require(Fixtures.makeImage(in: directory, width: 320, height: 200, type: .png))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        let second = try await preparer.prepareImage(LocalImage(fileURL: url))
        let sourceHash = try ContentHasher.sha256Hex(ofFileAt: url)

        #expect(second.contentHash == sourceHash)
        #expect(second.contentHash != first.contentHash)
    }

    @Test func thumbnailFitsTheMaximumPixelSize() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = try #require(Fixtures.makeImage(in: directory, width: 2000, height: 1000, type: .jpeg))
        let small = try #require(Fixtures.makeImage(in: directory, width: 100, height: 50, type: .png))
        let missing = directory.appendingPathComponent("missing.png")

        let thumbnail = try #require(await ImageThumbnail.image(at: large, maxPixelSize: 256))
        let unscaled = try #require(await ImageThumbnail.image(at: small, maxPixelSize: 256))
        let none = await ImageThumbnail.image(at: missing, maxPixelSize: 256)

        #expect(thumbnail.width == 256 && thumbnail.height == 128)
        #expect(unscaled.width == 100 && unscaled.height == 50)
        #expect(none == nil)
    }

    /// A server's link is never opened here: `ServerImageReader` checks it first.
    @Test(arguments: ["http://cdn.example.org/a.png", "https://cdn.example.org/a.png"])
    func aThumbnailIsNeverReadFromALink(link: String) async throws {
        #expect(await ImageThumbnail.image(at: try #require(URL(string: link)), maxPixelSize: 256) == nil)
    }

    @Test func aThumbnailIsDecodedFromBytes() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try #require(Fixtures.makeImage(in: directory, width: 2000, height: 1000, type: .png))

        let thumbnail = try #require(await ImageThumbnail.image(data: try Data(contentsOf: file), maxPixelSize: 256))
        let none = await ImageThumbnail.image(data: Data("<html>".utf8), maxPixelSize: 256)

        #expect(thumbnail.width == 256 && thumbnail.height == 128)
        #expect(none == nil)
    }

    @Test func downscalesOversizedImage() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(Fixtures.makeImage(in: directory, width: 6000, height: 300, type: .png))
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let file = try await preparer.prepareImage(LocalImage(fileURL: url))
        let size = try #require(Fixtures.imageSize(at: file.fileURL))

        #expect(file.contentType == "image/jpeg")
        #expect(size.width == MediaPreparer.maximumImagePixelSize)
        #expect(size.height == 205 || size.height == 204)
    }

    @Test func rejectsNonImage() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.heic")
        try Data("plain text".utf8).write(to: url)
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        await #expect(throws: MediaError.unreadableImage) {
            try await preparer.prepareImage(LocalImage(fileURL: url))
        }
    }
}

@Suite struct ContentHasherTests {
    @Test(arguments: [
        (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (
            Data(repeating: 97, count: 3 * 1024 * 1024 + 17),
            "8cb91458835f2fefeb12cf01e67a7ea18523a0567d4835a974dc04c2ddbb955b"
        ),
    ])
    func matchesKnownDigest(contents: Data, expected: String) throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("abc.txt")
        try contents.write(to: url)

        let digest = try ContentHasher.sha256Hex(ofFileAt: url)

        #expect(digest == expected)
    }
}
