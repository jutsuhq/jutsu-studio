import Foundation
import Testing

@testable import JutsuCore

/// Kling O3's video reference, added as a `models.json` entry.
@Suite struct KlingO3Tests {
    static func spec(seconds: TimeInterval, resolution: Resolution, prompt: String = "she spins") throws -> JobSpec {
        JobSpec(
            mode: .motionTransfer, model: try #require(VideoModel(rawValue: "klingO3VideoReference")),
            source: SourceClip(
                fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 30,
                pixelSize: PixelSize(width: 1280, height: 720), range: 0...seconds),
            prompt: prompt, resolution: resolution)
    }

    @Test func itIsAKlingWithItsOwnLimits() throws {
        let model = try #require(VideoModel(rawValue: "klingO3VideoReference"))
        #expect(model.title == "Kling O3")
        #expect(model.family == VideoModel.klingMotionControl.family)
        #expect(model.modes == [.motionTransfer])
        #expect(model.limits(for: .motionTransfer).duration == 3...10)
        #expect(model.limits(for: .motionTransfer).referenceImages == 0...4)
        #expect(model.declares(.quality) && !model.offersDraft && !model.makesClipsWithoutSource)
    }

    /// One endpoint for both qualities (Standard below 1080p, Pro at 1080p). Its page gives only a range, $0.126 to
    /// $0.168 a second, naming no mode, so both are priced up to its top.
    @Test func itIsPricedUpToTheTopOfItsRange() throws {
        let pricing = try Pricing.bundled()
        let standard = try Self.spec(seconds: 5, resolution: .p720)
        let pro = try Self.spec(seconds: 5, resolution: .p1080)
        #expect(standard.endpointID == "kling-video/o3/video-reference")
        #expect(pro.endpointID == "kling-video/o3/video-reference")
        for spec in [standard, pro] {
            #expect(try pricing.cost(for: spec) == .usd(Decimal(string: "0.84") ?? 0, isEstimate: true))
            #expect(pricing.isUpperBound(for: spec))
        }
    }

    /// The schema requires a prompt, and takes 3–10 s.
    @Test func itNeedsAPromptAndAShortSelection() throws {
        #expect(Validation.check(try Self.spec(seconds: 5, resolution: .p720)).isEmpty)
        #expect(Validation.check(try Self.spec(seconds: 5, resolution: .p720, prompt: " ")).contains(.promptRequired))
        #expect(Validation.check(try Self.spec(seconds: 12, resolution: .p720)).contains(.durationTooLong(12)))
    }
}
