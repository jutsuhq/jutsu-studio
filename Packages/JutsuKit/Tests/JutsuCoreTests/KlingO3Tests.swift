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

    /// One endpoint for both qualities (Standard below 1080p, Pro at 1080p), each with its own rate: $0.0945 a second
    /// at 720p, $0.1263 at 1080p. No 480p rate is published, so 480p is priced up to the 720p one.
    @Test func itIsPricedByResolutionAnd480pUpToThe720pRate() throws {
        let pricing = try Pricing.bundled()
        let draft = try Self.spec(seconds: 5, resolution: .p480)
        let standard = try Self.spec(seconds: 5, resolution: .p720)
        let pro = try Self.spec(seconds: 5, resolution: .p1080)
        #expect(standard.endpointID == "kling-video/o3/video-reference")
        #expect(pro.endpointID == "kling-video/o3/video-reference")
        #expect(try pricing.cost(for: draft) == .usd(Decimal(string: "0.4725") ?? 0, isEstimate: true))
        #expect(pricing.isUpperBound(for: draft))
        #expect(try pricing.cost(for: standard) == .usd(Decimal(string: "0.4725") ?? 0, isEstimate: true))
        #expect(!pricing.isUpperBound(for: standard))
        #expect(try pricing.cost(for: pro) == .usd(Decimal(string: "0.6315") ?? 0, isEstimate: true))
        #expect(!pricing.isUpperBound(for: pro))
    }

    /// The schema requires a prompt, and takes 3–10 s.
    @Test func itNeedsAPromptAndAShortSelection() throws {
        #expect(Validation.check(try Self.spec(seconds: 5, resolution: .p720)).isEmpty)
        #expect(Validation.check(try Self.spec(seconds: 5, resolution: .p720, prompt: " ")).contains(.promptRequired))
        #expect(Validation.check(try Self.spec(seconds: 12, resolution: .p720)).contains(.durationTooLong(12)))
    }
}
