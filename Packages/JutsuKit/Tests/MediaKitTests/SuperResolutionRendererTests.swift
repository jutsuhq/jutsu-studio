import AVFoundation
import CoreVideo
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

/// Upscale › On this Mac's sizes, turning and sound, with a stand-in for VideoToolbox's scaler, whose model the test
/// Macs may not have.
@Suite struct SuperResolutionRendererTests {
    /// Leaves the 4× frames as the pool gives them; records the sizes it was started for and given.
    final class RecordingScaler: FrameScaling {
        private(set) var startedFor: PixelSize?
        private(set) var inputs: [PixelSize] = []
        private(set) var hadPrevious: [Bool] = []

        func start(size: PixelSize, modelProgress: @escaping @Sendable (Double) -> Void) async throws -> FrameFormat {
            startedFor = size
            modelProgress(1)
            return .plain(kCVPixelFormatType_32BGRA)
        }

        func scale(
            _ frame: TimedFrame, previous: (source: TimedFrame, output: TimedFrame)?, into target: TimedFrame
        )
            async throws
        {
            inputs.append(
                PixelSize(width: CVPixelBufferGetWidth(frame.buffer), height: CVPixelBufferGetHeight(frame.buffer)))
            hadPrevious.append(previous != nil)
        }

        func end() {}
    }

    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [OnDeviceProgress] = []
        var all: [OnDeviceProgress] { lock.withLock { stored } }
        func add(_ progress: OnDeviceProgress) { lock.withLock { stored.append(progress) } }
    }

    private struct Written {
        let size: CGSize
        let frames: Int
        let hasAudio: Bool
        let codec: FourCharCode
    }

    private func written(_ url: URL) async throws -> Written {
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (size, formats) = try await video.load(.naturalSize, .formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        let format = try #require(formats.first)
        return Written(
            size: size, frames: frames, hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
            codec: CMFormatDescriptionGetMediaSubType(format))
    }

    @Test func everyFrameGrowsFourTimesAndTheSoundStays() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let silent = try await Fixtures.makeVideo(in: folder, width: 160, height: 90, seconds: 1, frameRate: 10)
        let clip = try await Fixtures.addingTone(to: silent, in: folder)
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = RecordingScaler()
        let reports = Reports()

        let result = try await SuperResolutionRenderer.renderVideo(
            source: clip, to: output, scaler: scaler, progress: { reports.add($0) })
        let file = try await written(output)

        #expect(result.pixelSize == PixelSize(width: 640, height: 360))
        #expect(abs(result.duration - 1) < 0.1)
        #expect(file.size == CGSize(width: 640, height: 360))
        #expect(file.frames == 10)
        #expect(file.hasAudio)
        #expect(file.codec == kCMVideoCodecType_H264)
        #expect(scaler.startedFor == PixelSize(width: 160, height: 90))
        #expect(scaler.hadPrevious == [false] + Array(repeating: true, count: 9))
        #expect(reports.all.first == .downloadingModel(1))
        #expect(reports.all.last == .working(1))
    }

    @Test func aPortraitFrameTheScalerRefusesIsTurnedForItAndBack() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Fixtures.makeVideo(in: folder, width: 90, height: 160, seconds: 1, frameRate: 5)
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = RecordingScaler()

        // A scaler limit as wide as the clip is tall, so only the turned frame fits.
        let result = try await SuperResolutionRenderer.renderVideo(
            source: clip, to: output, scaler: scaler, limit: PixelSize(width: 160, height: 90), progress: { _ in })

        #expect(scaler.startedFor == PixelSize(width: 160, height: 90))
        #expect(scaler.inputs.allSatisfy { $0 == PixelSize(width: 160, height: 90) })
        #expect(result.pixelSize == PixelSize(width: 360, height: 640))
        #expect(try await written(output).size == CGSize(width: 360, height: 640))
    }

    /// A target below 4× is what the file is written at, the scaler still run at its 4×, turned or not.
    @Test func aSmallerTargetIsWhatTheFileIsWrittenAt() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Fixtures.makeVideo(in: folder, width: 90, height: 160, seconds: 1, frameRate: 5)
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = RecordingScaler()

        let result = try await SuperResolutionRenderer.renderVideo(
            source: clip, to: output, scaler: scaler, target: .factor(2), limit: PixelSize(width: 160, height: 90),
            progress: { _ in })

        #expect(scaler.startedFor == PixelSize(width: 160, height: 90))
        #expect(result.pixelSize == PixelSize(width: 180, height: 320))
        let file = try await written(output)
        #expect(file.size == CGSize(width: 180, height: 320) && file.frames == 5)
    }

    @Test func aTargetNotLargerThanTheSourceIsRefused() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Fixtures.makeVideo(in: folder, width: 160, height: 90, seconds: 1, frameRate: 2)
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = RecordingScaler()

        await #expect(throws: SuperResolutionRenderer.targetNotLarger) {
            _ = try await SuperResolutionRenderer.renderVideo(
                source: clip, to: output, scaler: scaler, target: .shortSide(90), progress: { _ in })
        }
        #expect(scaler.startedFor == nil)
    }

    @Test func aVideoOver720pIsRefused() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Fixtures.makeVideo(in: folder, width: 1440, height: 810, seconds: 1, frameRate: 2)
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let scaler = RecordingScaler()

        await #expect(throws: MediaError.engineUnavailable) {
            _ = try await SuperResolutionRenderer.renderVideo(
                source: clip, to: output, scaler: scaler, progress: { _ in })
        }
        #expect(scaler.startedFor == nil)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func turningClockwiseThenBackGivesTheSameFrame() throws {
        let source = try FramePool(size: PixelSize(width: 4, height: 2), pixelFormat: kCVPixelFormatType_32BGRA).make()
        let turned = try FramePool(size: PixelSize(width: 2, height: 4), pixelFormat: kCVPixelFormatType_32BGRA).make()
        let back = try FramePool(size: PixelSize(width: 4, height: 2), pixelFormat: kCVPixelFormatType_32BGRA).make()
        fill(source) { x, y in UInt8(1 + y * 4 + x) }

        try FrameRotator(.clockwise).rotate(source, into: turned)
        try FrameRotator(.counterclockwise).rotate(turned, into: back)

        // Clockwise, the bottom-left pixel comes to the top left.
        #expect(pixel(turned, x: 0, y: 0) == pixel(source, x: 0, y: 1))
        #expect(pixel(turned, x: 1, y: 0) == pixel(source, x: 0, y: 0))
        for y in 0..<2 {
            for x in 0..<4 { #expect(pixel(back, x: x, y: y) == pixel(source, x: x, y: y)) }
        }
    }

    /// Writes `value(x, y)` into the blue byte of each pixel and makes the pixel opaque.
    private func fill(_ buffer: CVPixelBuffer, _ value: (Int, Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let pixel = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = value(x, y)
                pixel[1] = 0
                pixel[2] = 0
                pixel[3] = 255
            }
        }
    }

    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        return base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self).pointee
    }
}
