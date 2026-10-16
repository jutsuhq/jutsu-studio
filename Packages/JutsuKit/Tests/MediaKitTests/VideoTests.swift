import AVFoundation
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

private func clip(
    _ url: URL, range: ClosedRange<TimeInterval>, allowsUpscale: Bool = false
) async throws -> SourceClip {
    let info = try await MediaProbe.probe(url)
    return SourceClip(
        fileURL: url, duration: info.duration, pixelSize: info.pixelSize, range: range, allowsUpscale: allowsUpscale)
}

private func modificationDate(of url: URL) throws -> Date? {
    try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

@Suite struct MediaProbeTests {
    @Test func readsVideoProperties() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 6, frameRate: 30)

        let info = try await MediaProbe.probe(url)

        #expect(abs(info.duration - 6) < 0.1)
        #expect(info.pixelSize == PixelSize(width: 720, height: 480))
        #expect(info.codec == "avc1")
        #expect(abs(info.frameRate - 30) < 0.5)
        #expect(info.fileSize > 0)
        #expect(!info.hasAudio)
    }

    @Test func rejectsUndecodableFile() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.webm")
        try Data("not a video container".utf8).write(to: url)

        await #expect(throws: MediaError.unsupportedFormat) {
            try await MediaProbe.probe(url)
        }
    }

    @Test func cancellationIsNotReportedAsUnsupported() async {
        struct LoadFailed: Error {}
        await #expect(throws: CancellationError.self) {
            try await MediaProbe.unsupportedOnFailure { () throws -> Int in throw CancellationError() }
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await MediaProbe.unsupportedOnFailure { () throws -> Int in throw LoadFailed() }
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        await #expect(throws: MediaError.unsupportedFormat) {
            try await MediaProbe.unsupportedOnFailure { () throws -> Int in throw LoadFailed() }
        }
    }
}

@Suite struct VideoPreparerTests {
    @Test func trimsAndTranscodesToH264MP4() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 6)
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let source = try await clip(url, range: 1...5)
        let file = try await preparer.prepareVideo(source) { _ in }
        let info = try await MediaProbe.probe(file.fileURL)
        let outputHash = try ContentHasher.sha256Hex(ofFileAt: file.fileURL)

        #expect(abs(info.duration - 4) < 0.1)
        #expect(info.codec == "avc1")
        #expect(info.pixelSize == PixelSize(width: 720, height: 480))
        #expect(file.fileURL.pathExtension == "mp4")
        #expect(file.contentType == "video/mp4")
        #expect(file.byteCount == info.fileSize)
        #expect(file.byteCount <= MediaPreparer.fileLengthLimit)
        #expect(file.contentHash == outputHash)
    }

    @Test func transcodesHEVCMovToH264() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Some virtualised CI Macs have no HEVC encoder; there is nothing to test without the fixture.
        guard
            let url = try? await Fixtures.makeVideo(
                in: directory, width: 1280, height: 720, seconds: 5, codec: .hevc, fileType: .mov)
        else { return }
        let input = try await MediaProbe.probe(url)
        #expect(input.codec == "hvc1")
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))
        let source = try await clip(url, range: 0...5)

        let file = try await preparer.prepareVideo(source) { _ in }
        let output = try await MediaProbe.probe(file.fileURL)

        #expect(output.codec == "avc1")
        #expect(output.pixelSize == PixelSize(width: 1280, height: 720))
    }

    @Test func trimsLongClipToThirtySeconds() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 35, frameRate: 1)
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let source = try await clip(url, range: 2...32)

        let file = try await preparer.prepareVideo(source) { _ in }
        let info = try await MediaProbe.probe(file.fileURL)

        #expect(abs(info.duration - 30) < 0.1)
        #expect(file.byteCount <= MediaPreparer.fileLengthLimit)
    }

    @Test func upscalesSmallFrameForObjectSwap() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 6)
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        let source = try await clip(url, range: 0...4, allowsUpscale: true)

        let file = try await preparer.prepareVideo(source) { _ in }
        let info = try await MediaProbe.probe(file.fileURL)

        #expect(info.pixelSize == PixelSize(width: 784, height: 524))
    }

    @Test func secondCallReturnsCachedFile() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 6)
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))
        let source = try await clip(url, range: 0...4)

        let first = try await preparer.prepareVideo(source) { _ in }
        let created = try modificationDate(of: first.fileURL)
        let second = try await preparer.prepareVideo(source) { _ in }
        let reused = try modificationDate(of: second.fileURL)
        let otherSource = try await clip(url, range: 1...5)
        let other = try await preparer.prepareVideo(otherSource) { _ in }

        #expect(second == first)
        #expect(reused == created)
        #expect(other.fileURL != first.fileURL)
    }

    @Test func reencoderFitsByteLimit() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 6)
        let output = directory.appendingPathComponent("reencoded.mp4")
        let request = VideoRequest(
            sourceURL: url,
            timeRange: CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 5, preferredTimescale: 600)),
            upscaledSize: PixelSize(width: 784, height: 524),
            byteLimit: 2 * 1024 * 1024
        )

        try await VideoReencoder.reencode(request, to: output) { _ in }
        let info = try await MediaProbe.probe(output)

        #expect(info.codec == "avc1")
        #expect(info.pixelSize == PixelSize(width: 784, height: 524))
        #expect(abs(info.duration - 4) < 0.1)
        #expect(info.fileSize <= request.byteLimit)
    }

    @Test func bitRateLeavesRoomForAudioAndOverhead() {
        let limit = MediaPreparer.fileLengthLimit
        let video = VideoReencoder.videoBitRate(duration: 30, byteLimit: limit, hasAudio: true)
        let bytes = Double(video + VideoReencoder.audioBitRate) * 30 / 8
        #expect(bytes <= Double(limit) * 0.91)
        #expect(bytes >= Double(limit) * 0.85)
    }

    @Test func thumbnailStripReturnsRequestedCount() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Fixtures.makeVideo(in: directory, seconds: 6)

        let images = try await ThumbnailStrip.images(for: url, count: 5)

        #expect(images.count == 5)
        #expect(images.allSatisfy { $0.width <= 320 && $0.height <= 320 })
    }
}

@Suite struct AudioRestorerTests {
    /// A Seedance Edit came back silent and shorter than its source (3.71 s from 4.02 s, live on 2026-10-15), and a
    /// background cut-out silent: the source's sound goes on cut to the result's length, never padded past it.
    @Test(arguments: [(Mode.edit, nil as PostAction?), (.extend, .removeBackground)])
    func aShorterSilentResultGetsTheSourcesSoundCutToItsLength(mode: Mode, operation: PostAction?) async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Fixtures.addingTone(
            to: try await Fixtures.makeVideo(in: directory, seconds: 4), in: directory)
        let downloaded = try await Fixtures.makeVideo(in: directory, seconds: 3)
        let result = directory.appendingPathComponent(".result.partial")
        try FileManager.default.moveItem(at: downloaded, to: result)
        let output = directory.appendingPathComponent(".result.audio.mp4")
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))
        let spec = JobSpec(
            mode: mode, model: .seedance25, source: try await clip(source, range: 0...4), resolution: .p480,
            operation: operation.map { PostOperation(action: $0) })

        #expect(try await preparer.restoreAudio(of: spec, result: result, to: output))

        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let videoLength = try await video.load(.timeRange).duration.seconds
        let audioLength = try await audio.load(.timeRange).duration.seconds
        #expect(abs(videoLength - 3) < 0.05)
        #expect(audioLength <= videoLength + 0.05 && audioLength > 2.9)
    }

    @Test func silentSourceLeavesTheResultAlone() async throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await Fixtures.makeVideo(in: directory, seconds: 6)
        let downloaded = try await Fixtures.makeVideo(in: directory, seconds: 4)
        // Downloads arrive without an extension.
        let result = directory.appendingPathComponent(".result.partial")
        try FileManager.default.moveItem(at: downloaded, to: result)
        let output = directory.appendingPathComponent(".result.audio.mp4")
        let preparer = MediaPreparer(workingDirectory: directory.appendingPathComponent("prepared"))

        for option in AudioOption.allCases {
            var spec = JobSpec(
                mode: .motionTransfer, source: try await clip(source, range: 1...5), resolution: .p480)
            spec.audio = option
            #expect(try await !preparer.restoreAudio(of: spec, result: result, to: output))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                == [
                    ".result.partial", source.lastPathComponent,
                ].sorted())
    }
}
