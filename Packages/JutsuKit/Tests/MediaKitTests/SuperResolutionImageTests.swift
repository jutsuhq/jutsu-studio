import Foundation
import ImageIO
import JutsuCore
import Testing
import UniformTypeIdentifiers

@testable import MediaKit

/// Upscale › On this Mac for an image: size, orientation and file type, with the stand-in scaler.
@Suite struct SuperResolutionImageTests {
    private typealias Scaler = SuperResolutionRendererTests.RecordingScaler

    private func type(at url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(CGImageSourceGetType).map { $0 as String }
    }

    @Test func aPNGGrowsFourTimesAndStaysAPNG() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(Fixtures.makeImage(in: folder, width: 160, height: 90, type: .png))
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = Scaler()

        let result = try await SuperResolutionRenderer.renderImage(
            source: image, to: output, scaler: scaler, progress: { _ in })

        #expect(scaler.startedFor == PixelSize(width: 160, height: 90))
        #expect(scaler.hadPrevious == [false])
        #expect(result.pixelSize == PixelSize(width: 640, height: 360))
        #expect(result.fileExtension == "png")
        #expect(type(at: output) == UTType.png.identifier)
        #expect(Fixtures.imageSize(at: output).map { [$0.width, $0.height] } == [640, 360])
    }

    @Test func aSmallerTargetIsWhatTheImageIsWrittenAt() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(Fixtures.makeImage(in: folder, width: 160, height: 90, type: .png))
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = Scaler()

        let result = try await SuperResolutionRenderer.renderImage(
            source: image, to: output, scaler: scaler, target: .shortSide(270), progress: { _ in })

        #expect(scaler.startedFor == PixelSize(width: 160, height: 90))
        #expect(result.pixelSize == PixelSize(width: 480, height: 270))
        #expect(Fixtures.imageSize(at: output).map { [$0.width, $0.height] } == [480, 270])
    }

    @Test func aTurnedJPEGIsUpscaledUpright() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Stored 160×90 with EXIF orientation 6: shown 90×160.
        let image = try #require(
            Fixtures.makeImage(in: folder, width: 160, height: 90, type: .jpeg, orientation: 6))
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = Scaler()

        let result = try await SuperResolutionRenderer.renderImage(
            source: image, to: output, scaler: scaler, progress: { _ in })

        #expect(scaler.startedFor == PixelSize(width: 90, height: 160))
        #expect(result.pixelSize == PixelSize(width: 360, height: 640))
        #expect(result.fileExtension == "jpg")
        #expect(type(at: output) == UTType.jpeg.identifier)
        #expect(ImageThumbnail.size(at: output) == PixelSize(width: 360, height: 640))
    }

    @Test func theHeaderSaysWhetherThereIsTransparency() throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The fixture draws with premultiplied alpha, which PNG keeps and JPEG drops.
        let png = try #require(Fixtures.makeImage(in: folder, width: 8, height: 8, type: .png))
        let jpeg = try #require(Fixtures.makeImage(in: folder, width: 8, height: 8, type: .jpeg))
        #expect(ImageThumbnail.hasAlpha(at: png))
        #expect(!ImageThumbnail.hasAlpha(at: jpeg))
    }

    @Test func anImageOver1080pIsRefused() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try #require(Fixtures.makeImage(in: folder, width: 1200, height: 2000, type: .png))
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = Scaler()

        await #expect(throws: MediaError.engineUnavailable) {
            _ = try await SuperResolutionRenderer.renderImage(
                source: image, to: output, scaler: scaler, progress: { _ in })
        }
        #expect(scaler.startedFor == nil)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
