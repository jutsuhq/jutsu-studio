import AVFoundation
import CoreGraphics
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

@Suite struct ClipJoinerTests {
    /// The selection of the original and the extension end to end: as long as both together less the extension's
    /// first frame (0.2 s at 5 fps), so there is no gap at the seam, at the original's frame size although the
    /// extension is smaller.
    @Test func joinsTheSelectionAndTheExtensionWithoutAGap() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await Fixtures.makeVideo(in: directory, width: 720, height: 480, seconds: 3)
        let addition = try await Fixtures.makeVideo(in: directory, width: 360, height: 240, seconds: 2)
        let output = directory.appendingPathComponent("joined.mp4")

        try await ClipJoiner.join(original, range: 1...3, then: addition, to: output)
        let info = try await MediaProbe.probe(output)

        #expect(abs(info.duration - 3.8) < 0.05)
        #expect(info.pixelSize == PixelSize(width: 720, height: 480))
        #expect(info.codec == "avc1")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!leftovers.contains { $0.contains(".partial") })
    }

    /// Issue #134: an Extend result starts on the original's last frame. The joined file shows it once, the
    /// extension's next frame follows, and each part's sound plays under its own picture, although the parts run at
    /// different frame rates.
    @Test func theSeamFrameIsShownOnceAndTheSoundStaysInStep() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 10 fps, grey 20, 40, … 200; the last frame is 200.
        let originalPicture = try await Fixtures.makeVideo(
            in: directory, width: 320, height: 240, seconds: 1, frameRate: 10, shade: { Int32(20 + 20 * $0) })
        // 5 fps, starting on the original's last frame: 200, then 60, 100, 140, 180.
        let additionPicture = try await Fixtures.makeVideo(
            in: directory, width: 320, height: 240, seconds: 1, frameRate: 5,
            shade: { $0 == 0 ? 200 : Int32(20 + 40 * $0) })
        let original = try await Fixtures.addingTone(to: originalPicture, in: directory)
        let addition = try await Fixtures.addingTone(to: additionPicture, in: directory)
        let output = directory.appendingPathComponent("joined.mp4")

        try await ClipJoiner.join(original, range: 0...1, then: addition, to: output)

        let asset = AVURLAsset(url: output)
        let picture = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let pictureRange = try await picture.load(.timeRange)
        let soundRange = try await sound.load(.timeRange)
        // One second of each, less the extension's first frame of 0.2 s.
        #expect(abs(pictureRange.duration.seconds - 1.8) < 0.05)
        // Within one frame (0.1 s at the joined rate) of the picture at both ends.
        #expect(abs(soundRange.start.seconds - pictureRange.start.seconds) < 0.1)
        #expect(abs(soundRange.end.seconds - pictureRange.end.seconds) < 0.1)

        #expect(abs(try await Self.shade(of: output, at: 0.95) - 200) < 16)
        #expect(abs(try await Self.shade(of: output, at: 1.05) - 60) < 16)
        #expect(abs(try await Self.shade(of: output, at: 1.25) - 100) < 16)
    }

    /// The grey level of the frame shown at `seconds`.
    private static func shade(of url: URL, at seconds: TimeInterval) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(
                CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(pixel[1])
    }

    @Test func neverReplacesAnExistingFile() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await Fixtures.makeVideo(in: directory, seconds: 1)
        let addition = try await Fixtures.makeVideo(in: directory, seconds: 1)
        let output = directory.appendingPathComponent("joined.mp4")
        try Data("keep me".utf8).write(to: output)

        await #expect(throws: (any Error).self) {
            try await ClipJoiner.join(original, range: 0...1, then: addition, to: output)
        }
        #expect(try Data(contentsOf: output) == Data("keep me".utf8))
    }
}
