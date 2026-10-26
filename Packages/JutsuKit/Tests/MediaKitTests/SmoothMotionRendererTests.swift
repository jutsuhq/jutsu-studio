import AVFoundation
import CoreVideo
import Foundation
import JutsuCore
import Testing

@testable import MediaKit

/// Smooth Motion's frame timing, sound and cut handling, with a stand-in for VideoToolbox's engine, whose model the
/// test Macs may not have.
@Suite struct SmoothMotionRendererTests {
    /// Fills the frames between with the earlier frame; records the phases it was asked for.
    final class CopyingInterpolator: FrameInterpolating {
        private(set) var calls: [[Float]] = []
        private(set) var isRunning = false

        func start(size: PixelSize) throws -> FrameFormat {
            isRunning = true
            return .plain(kCVPixelFormatType_32BGRA)
        }

        func interpolate(
            from earlier: TimedFrame, to later: TimedFrame, phases: [Float], into targets: [TimedFrame]
        )
            async throws
        {
            calls.append(phases)
            for target in targets {
                CVPixelBufferLockBaseAddress(earlier.buffer, .readOnly)
                CVPixelBufferLockBaseAddress(target.buffer, [])
                memcpy(
                    CVPixelBufferGetBaseAddress(target.buffer), CVPixelBufferGetBaseAddress(earlier.buffer),
                    min(CVPixelBufferGetDataSize(target.buffer), CVPixelBufferGetDataSize(earlier.buffer)))
                CVPixelBufferUnlockBaseAddress(target.buffer, [])
                CVPixelBufferUnlockBaseAddress(earlier.buffer, .readOnly)
            }
        }

        func end() { isRunning = false }
    }

    private struct Written {
        let frames: Int
        let frameRate: Float
        let duration: TimeInterval
        let hasAudio: Bool
    }

    private func written(_ url: URL) async throws -> Written {
        // The ".partial" name says nothing of the type.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        return Written(
            frames: frames, frameRate: try await video.load(.nominalFrameRate),
            duration: try await asset.load(.duration).seconds,
            hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty)
    }

    private func render(_ motion: SmoothMotion, _ source: URL, in folder: URL) async throws -> (URL, [[Float]]) {
        // The name the app writes to while it runs.
        let output = folder.appending(path: ".\(UUID().uuidString).partial")
        let interpolator = CopyingInterpolator()
        let result = try await SmoothMotionRenderer.render(
            motion, source: source, to: output, interpolator: interpolator, progress: { _ in })
        #expect(!interpolator.isRunning)
        #expect(result.pixelSize == PixelSize(width: 160, height: 90))
        #expect(abs(result.duration - Double(motion.slowdown)) < 0.01)
        return (output, interpolator.calls)
    }

    @Test func sixtyFramesASecondKeepsTheLengthAndTheSound() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let silent = try await Fixtures.makeVideo(in: folder, width: 160, height: 90, seconds: 1, frameRate: 10)
        let clip = try await Fixtures.addingTone(to: silent, in: folder)

        let (output, calls) = try await render(.fps60, clip, in: folder)
        let result = try await written(output)

        #expect(result.frames == 60)
        #expect(abs(result.frameRate - 60) < 0.5)
        #expect(abs(result.duration - 1) < 0.1)
        #expect(result.hasAudio)
        // Nine pairs, five frames made between each.
        #expect(calls.count == 9)
        #expect(calls.allSatisfy { $0.count == 5 })
    }

    @Test func slowMotionPlaysLongerAtTheClipsRateWithoutSound() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let silent = try await Fixtures.makeVideo(in: folder, width: 160, height: 90, seconds: 1, frameRate: 10)
        let clip = try await Fixtures.addingTone(to: silent, in: folder)

        let (output, calls) = try await render(.slowMotion4x, clip, in: folder)
        let result = try await written(output)

        #expect(result.frames == 40)
        #expect(abs(result.frameRate - 10) < 0.5)
        #expect(abs(result.duration - 4) < 0.2)
        #expect(!result.hasAudio)
        #expect(calls.first == [0.25, 0.5, 0.75])
    }

    @Test func noFramesAreMadeAcrossACut() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Five dark frames, then five bright ones: a hard cut between frames 4 and 5.
        let clip = try await Fixtures.makeVideo(
            in: folder, width: 160, height: 90, seconds: 1, frameRate: 10, shade: { $0 < 5 ? 40 : 200 })

        let (output, calls) = try await render(.slowMotion2x, clip, in: folder)

        #expect(try await written(output).frames == 20)
        #expect(calls.count == 8)
    }

    @Test func aCanceledRunLeavesNoFile() async throws {
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await Fixtures.makeVideo(in: folder, width: 160, height: 90, seconds: 1, frameRate: 10)
        let output = folder.appending(path: ".\(UUID().uuidString).partial")

        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await SmoothMotionRenderer.render(
                .fps60, source: clip, to: output, interpolator: CopyingInterpolator(), progress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func thumbnailsTellACutFromTheNextFrame() throws {
        let sampler = LumaSampler()
        let dark = try frame(shade: 40)
        let darker = try frame(shade: 44)
        let bright = try frame(shade: 200)

        #expect(!CutDetector.isCut(sampler.thumbnail(of: dark), sampler.thumbnail(of: darker)))
        #expect(CutDetector.isCut(sampler.thumbnail(of: dark), sampler.thumbnail(of: bright)))
        // 640×360 frames make 360×203 thumbnails, as 1920×1080 ones do.
        #expect(sampler.thumbnail(of: dark).count == 360 * 203)
    }

    private func frame(shade: Int32) throws -> CVPixelBuffer {
        let buffer = try FramePool(size: PixelSize(width: 640, height: 360), pixelFormat: kCVPixelFormatType_32BGRA)
            .make()
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), shade, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
