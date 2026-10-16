import Foundation
import HiggsfieldMCP
import JutsuCore
import Testing

@testable import HiggsfieldProviders

@Suite struct HistoryMappingTests {
    /// The live model names of the account's history; Genjutsu's Style jobs report `restyle` (issue #123).
    @Test func historyIDsMapToTheirModelsAndModes() {
        let kinds = ["hf_mult_motion_control", "hf_mult_replace_object", "seedance_2_5", "kling3_0_motion_control"]
            .map { HistoryMapping.kind(ofModel: $0).map { "\($0.0.rawValue) \($0.1.rawValue)" } }
        #expect(
            kinds == [
                "motionTransfer genjutsu", "objectSwap genjutsu", "motionTransfer seedance25",
                "motionTransfer klingMotionControl",
            ])
        #expect(HistoryMapping.kind(ofModel: "restyle").map(\.1) == .genjutsu)
        #expect(HistoryMapping.kind(ofModel: "hf_mult_restyle") == nil)
        #expect(HistoryMapping.kind(ofModel: "veo3") == nil)
    }

    private func imageGeneration(
        type: String = "image", status: String = "completed",
        output: URL? = URL(string: "https://cdn.example.com/out.png")
    ) -> PastGeneration {
        PastGeneration(
            id: "img-1", type: type, status: status, model: "seedream_5_0", createdAt: Date(timeIntervalSince1970: 0),
            outputURL: output, width: 1024, height: 1024, prompt: "neon dance", media: [])
    }

    @Test func completedImagesMapWithTheirModelName() {
        let image = HistoryMapping.image(imageGeneration())
        #expect(image?.id == "img-1")
        #expect(image?.prompt == "neon dance")
        #expect(image?.model == "seedream_5_0")
        #expect(image?.aspectRatio == "1:1")
        #expect(image?.outputURL == URL(string: "https://cdn.example.com/out.png"))
    }

    @Test func unfinishedOrUndownloadableImagesAreLeftOut() {
        #expect(HistoryMapping.image(imageGeneration(status: "in_progress")) == nil)
        #expect(HistoryMapping.image(imageGeneration(type: "video")) == nil)
        #expect(HistoryMapping.image(imageGeneration(output: nil)) == nil)
        #expect(
            HistoryMapping.image(imageGeneration(output: URL(string: "http://cdn.example.com/out.png"))) == nil)
    }

    @Test func cursorsPackBothStreamsAndStayReadable() {
        #expect(HistoryMapping.joinedCursor(video: nil, image: nil) == nil)
        let video = HistoryMapping.cursor(.string("v1"))
        let image = HistoryMapping.cursor(.string("i2"))
        let split = HistoryMapping.splitCursor(HistoryMapping.joinedCursor(video: video, image: image))
        #expect(split.video == .string("v1"))
        #expect(split.image == .string("i2"))
        // One stream past its last page: only the other is asked again.
        let half = HistoryMapping.splitCursor(HistoryMapping.joinedCursor(video: nil, image: image))
        #expect(half.video == nil)
        #expect(half.image == .string("i2"))
        // A video-only cursor from before images were listed keeps working, even one shaped like an array.
        #expect(HistoryMapping.splitCursor(video).video == .string("v1"))
        #expect(HistoryMapping.splitCursor(video).image == nil)
        #expect(HistoryMapping.splitCursor(HistoryMapping.cursor(.array([.string("a"), .string("b")]))).image == nil)
        #expect(HistoryMapping.splitCursor(nil).video == nil && HistoryMapping.splitCursor(nil).image == nil)
    }
}
