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

    @Test(arguments: [
        (PixelSize(width: 1920, height: 1080), true),
        (PixelSize(width: 1080, height: 1920), true),
        (PixelSize(width: 1600, height: 1000), true),
        (PixelSize(width: 1920, height: 1200), false),
        (PixelSize(width: 2048, height: 1024), false),
        (PixelSize(width: 0, height: 0), false),
    ])
    func imagesUpTo1080pAreOffered(size: PixelSize, isOffered: Bool) {
        #expect(OnDeviceUpscale.offersImage(size) == isOffered)
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
        #expect(OnDeviceAction.upscaleVideo(.full).engine == .videoSuperResolution)
        #expect(OnDeviceAction.upscaleVideo(.full).fileSuffix == "4x")
        #expect(OnDeviceEngine.imageSuperResolution.downloadsModel)
        #expect(OnDeviceAction.upscaleImage(.full).engine == .imageSuperResolution)
    }

    /// A delivery size keeps the source's shape with even sides, the short side exactly the one named; a factor
    /// scales both sides. 4× is the most, and a target must be larger than the source.
    @Test(arguments: [
        ("1080p", PixelSize(width: 720, height: 1280), PixelSize(width: 1080, height: 1920)),
        ("1080p", PixelSize(width: 576, height: 1024), PixelSize(width: 1080, height: 1920)),
        ("1080p", PixelSize(width: 554, height: 740), PixelSize(width: 1080, height: 1442)),
        ("2k", PixelSize(width: 1280, height: 720), PixelSize(width: 2560, height: 1440)),
        ("4k", PixelSize(width: 720, height: 1280), PixelSize(width: 2160, height: 3840)),
        ("2x", PixelSize(width: 480, height: 854), PixelSize(width: 960, height: 1708)),
        ("2.5x", PixelSize(width: 481, height: 270), PixelSize(width: 1202, height: 676)),
        ("4x", PixelSize(width: 480, height: 854), PixelSize(width: 1920, height: 3416)),
    ])
    func aTargetKeepsTheShape(name: String, source: PixelSize, output: PixelSize) throws {
        let target = try #require(OnDeviceUpscale.Target(name: name))
        #expect(target.output(for: source) == output)
    }

    @Test func aTargetMustBeLargerAndAtMostFourTimes() throws {
        #expect(OnDeviceUpscale.Target(name: "4x") == .full)
        #expect(OnDeviceUpscale.Target(name: "4K") == .shortSide(2160))
        for name in ["1x", "0.5x", "4.5x", "8k", "x", "1080", "nanx", "infx"] {
            #expect(OnDeviceUpscale.Target(name: name) == nil, "\(name)")
        }
        // 4k from 480p needs 4.5×; 1080p from a 1080 wide portrait clip adds nothing.
        #expect(OnDeviceUpscale.Target.shortSide(2160).output(for: PixelSize(width: 480, height: 854)) == nil)
        #expect(OnDeviceUpscale.Target.shortSide(1080).output(for: PixelSize(width: 1080, height: 1350)) == nil)
        #expect(OnDeviceAction.upscaleVideo(.shortSide(1080)).fileSuffix == "1080p")
        #expect(OnDeviceAction.upscaleImage(.shortSide(1440)).fileSuffix == "2k")
        #expect(OnDeviceAction.upscaleImage(try #require(OnDeviceUpscale.Target(name: "2.5x"))).fileSuffix == "2.5x")
        #expect(OnDeviceAction.upscaleVideo(try #require(OnDeviceUpscale.Target(name: "2x"))).fileSuffix == "2x")
    }
}
