import Foundation
import JutsuCore
import Testing

@Suite struct SmoothMotionTests {
    @Test func slowMotionKeepsTheClipsRateAndDropsTheSound() {
        #expect(SmoothMotion.fps60.outputFrameRate(source: 24) == 60)
        #expect(SmoothMotion.slowMotion2x.outputFrameRate(source: 29.97) == 30)
        #expect(SmoothMotion.slowMotion4x.outputFrameRate(source: 0) == 30)
        #expect(SmoothMotion.fps60.keepsAudio)
        #expect(!SmoothMotion.slowMotion2x.keepsAudio)
        #expect(!SmoothMotion.slowMotion4x.keepsAudio)
    }

    @Test func sixtyFramesASecondIsOfferedOnlyBelowFifty() {
        #expect(SmoothMotion.offered(sourceFrameRate: 30) == [.fps60, .slowMotion2x, .slowMotion4x])
        #expect(SmoothMotion.offered(sourceFrameRate: 60) == [.slowMotion2x, .slowMotion4x])
    }

    /// Feeds a clip's frame times through the timeline the way the renderer does, pair by pair.
    private func plan(_ timeline: inout FrameTimeline, sourceTimes: [TimeInterval]) -> [[FrameTimeline.Frame]] {
        sourceTimes.indices.map { index in
            timeline.frames(
                from: sourceTimes[index], until: index + 1 < sourceTimes.count ? sourceTimes[index + 1] : nil)
        }
    }

    @Test func sixtyFromThirtyMakesOneFrameBetweenEachPair() {
        var timeline = FrameTimeline(duration: 1, frameRate: 60, slowdown: 1)
        let pairs = plan(&timeline, sourceTimes: (0..<30).map { Double($0) / 30 })

        #expect(timeline.frameCount == 60)
        #expect(pairs.flatMap { $0 }.map(\.index) == Array(0..<60))
        #expect(pairs[0].map(\.phase) == [0, 0.5])
        #expect(abs(timeline.outputTime(of: 59) - 59.0 / 60) < 1e-9)
    }

    @Test func fourTimesSlowerSamplesQuarterPhasesAndLastsFourTimesAsLong() {
        var timeline = FrameTimeline(duration: 1, frameRate: 24, slowdown: 4)
        let pairs = plan(&timeline, sourceTimes: (0..<24).map { Double($0) / 24 })

        #expect(timeline.frameCount == 96)
        #expect(abs(timeline.outputTime(of: timeline.frameCount) - 4) < 1e-9)
        for pair in pairs.dropLast() {
            #expect(pair.map(\.phase).map { ($0 * 100).rounded() / 100 } == [0, 0.25, 0.5, 0.75])
        }
    }

    @Test func theLastFrameHoldsToTheEndAndAFirstFrameLateHoldsBack() {
        var timeline = FrameTimeline(duration: 1, frameRate: 10, slowdown: 1)
        // The clip's frames start late and stop early.
        let pairs = plan(&timeline, sourceTimes: [0.25, 0.5])

        #expect(pairs[0].map(\.index) == [0, 1, 2, 3, 4])
        #expect(pairs[0].prefix(3).allSatisfy { $0.phase == 0 })
        #expect(pairs[1].map(\.index) == [5, 6, 7, 8, 9])
        #expect(pairs[1].allSatisfy { $0.phase == 0 })
        #expect(timeline.frames(from: 1, until: nil).isEmpty)
    }

    @Test func cutsStandOutFromMotion() {
        let gradient = (0..<(64 * 36)).map { UInt8($0 % 64 * 3) }
        // The same picture moved two pixels to the side: motion, not a cut.
        let moved = gradient.indices.map { gradient[($0 + 2) % gradient.count] }
        let otherShot = gradient.map { 255 - $0 }

        #expect(CutDetector.difference(gradient, gradient) == 0)
        #expect(!CutDetector.isCut(gradient, moved))
        #expect(CutDetector.isCut(gradient, otherShot))
        #expect(CutDetector.difference(gradient, []) == nil)
        #expect(!CutDetector.isCut(gradient, [1, 2]))
    }

    @Test func h264OnlyWhereItHoldsTheFrame() {
        #expect(EnhanceCodec.of(output: PixelSize(width: 1920, height: 1080), sourceIsH264: true) == .h264)
        #expect(EnhanceCodec.of(output: PixelSize(width: 3416, height: 1920), sourceIsH264: true) == .h264)
        #expect(EnhanceCodec.of(output: PixelSize(width: 2880, height: 5120), sourceIsH264: true) == .hevc)
        #expect(EnhanceCodec.of(output: PixelSize(width: 1920, height: 1080), sourceIsH264: false) == .hevc)
    }

    @Test func largerFramesTakeLonger() {
        let small = OnDeviceEstimate.smoothMotion(
            duration: 10, frameRate: 24, pixelSize: PixelSize(width: 854, height: 480))
        let large = OnDeviceEstimate.smoothMotion(
            duration: 10, frameRate: 24, pixelSize: PixelSize(width: 1920, height: 1080))
        #expect(small > 10)
        #expect(large > small)
        // Per frame with the pixel count, not one step above 480p.
        let middle = OnDeviceEstimate.smoothMotion(
            duration: 10, frameRate: 24, pixelSize: PixelSize(width: 1280, height: 720))
        #expect(small < middle && middle < large)
        #expect(abs((small - 10) / 240 - 0.05) < 0.001)
    }
}
