import Foundation
import JutsuCore
import Testing

@Suite struct OnDeviceUpscaleTests {
    @Test(arguments: [
        (PixelSize(width: 854, height: 480), true),
        (PixelSize(width: 480, height: 854), true),
        (PixelSize(width: 1280, height: 720), true),
        (PixelSize(width: 720, height: 1280), true),
        (PixelSize(width: 1920, height: 1080), false),
        (PixelSize(width: 1080, height: 1920), false),
        (PixelSize(width: 1280, height: 800), false),
        (PixelSize(width: 0, height: 0), false),
    ])
    func videosUpTo720pAreOffered(size: PixelSize, isOffered: Bool) {
        #expect(OnDeviceUpscale.offersVideo(size) == isOffered)
    }

    @Test func aFrameThatFitsGoesInAsItIs() throws {
        let plan = try #require(OnDeviceUpscale.plan(for: PixelSize(width: 480, height: 854)))
        #expect(!plan.rotates)
        #expect(plan.scalerInput == PixelSize(width: 480, height: 854))
        #expect(plan.output == PixelSize(width: 1920, height: 3416))
    }

    @Test func aPortraitFrameTooTallIsTurned() throws {
        let plan = try #require(OnDeviceUpscale.plan(for: PixelSize(width: 720, height: 1280)))
        #expect(plan.rotates)
        #expect(plan.scalerInput == PixelSize(width: 1280, height: 720))
        #expect(plan.output == PixelSize(width: 2880, height: 5120))
        #expect(EnhanceCodec.of(output: plan.output, sourceIsH264: true) == .hevc)
    }

    @Test func aFrameNeitherWayFitsHasNoPlan() {
        #expect(OnDeviceUpscale.plan(for: PixelSize(width: 2048, height: 1080)) == nil)
        #expect(OnDeviceUpscale.plan(for: PixelSize(width: 1088, height: 1920)) == nil)
    }

    @Test func theEstimateFollowsTheBenchmark() {
        let small = PixelSize(width: 480, height: 854)
        let large = PixelSize(width: 720, height: 1280)
        // One second at 30 fps: 30 frames, plus the engine's start.
        let perFrameSmall = (OnDeviceEstimate.upscaleVideo(duration: 1, frameRate: 30, pixelSize: small) - 10) / 30
        let perFrameLarge = (OnDeviceEstimate.upscaleVideo(duration: 1, frameRate: 30, pixelSize: large) - 10) / 30
        #expect(abs(perFrameSmall - 1.0) < 0.01)
        #expect(abs(perFrameLarge - 1.95) < 0.01)
    }

    @Test func onlySuperResolutionDownloadsAModel() {
        #expect(!OnDeviceEngine.frameRateConversion.downloadsModel)
        #expect(OnDeviceEngine.videoSuperResolution.downloadsModel)
        #expect(OnDeviceAction.upscaleVideo.engine == .videoSuperResolution)
        #expect(OnDeviceAction.upscaleVideo.fileSuffix == "4x")
    }
}
