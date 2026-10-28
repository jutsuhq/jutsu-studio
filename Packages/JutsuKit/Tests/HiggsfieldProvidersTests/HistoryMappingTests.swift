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

    private func kling4(mode: String?, media: [PastMedia]) -> PastGeneration {
        var generation = PastGeneration(
            id: "k4-1", type: "video", status: "completed", model: "kling4_0",
            createdAt: Date(timeIntervalSince1970: 0),
            outputURL: URL(string: "https://cdn.example/out.mp4"), duration: 6, prompt: "dance", resolution: "720p",
            media: media)
        generation.mode = mode
        return generation
    }

    /// Kling 4.0 runs four of the app's jobs on one server model: its `params.mode` names which, and a clip from
    /// frames comes back with them as frames. Without a `mode` the media decide, as before: a source or images are
    /// references.
    @Test func kling4ComesBackInItsMode() throws {
        let video = PastMedia(role: .video, id: "video-1", url: URL(string: "https://cdn.example/in.mp4"))
        let image = PastMedia(role: .image, id: "image-1", url: URL(string: "https://cdn.example/a.png"))
        let second = PastMedia(role: .image, id: "image-2", url: URL(string: "https://cdn.example/b.png"))
        let start = PastMedia(role: .startFrame, id: "start", url: URL(string: "https://cdn.example/s.png"))
        let end = PastMedia(role: .endFrame, id: "end", url: URL(string: "https://cdn.example/e.png"))

        let edit = try #require(HistoryMapping.item(kling4(mode: "video-edit", media: [video, image])))
        #expect(edit.mode == .edit && edit.spec().mode == .edit && edit.inputs.video?.id == "video-1")
        #expect(HistoryMapping.item(kling4(mode: "video-edit", media: [image])) == nil)

        let reference = try #require(HistoryMapping.item(kling4(mode: "reference-to-video", media: [video, image])))
        #expect(reference.mode == .motionTransfer && !reference.referencesAreFrames)

        let text = try #require(HistoryMapping.item(kling4(mode: "text-to-video", media: [])))
        #expect(text.mode == .motionTransfer && text.spec().source == nil && text.spec().references.isEmpty)

        let framed = try #require(HistoryMapping.item(kling4(mode: "image-to-video", media: [end, start])))
        #expect(framed.inputs.images.map(\.id) == ["start", "end"])
        #expect(framed.referencesAreFrames && framed.spec().usesFrames)
        // History may name the frames `image`, as it does references: `image-to-video` still reads them as frames.
        let renamed = try #require(HistoryMapping.item(kling4(mode: "image-to-video", media: [image, second])))
        #expect(renamed.inputs.images.map(\.id) == ["image-1", "image-2"] && renamed.spec().usesFrames)

        let unnamed = try #require(HistoryMapping.item(kling4(mode: nil, media: [video, image])))
        #expect(unnamed.mode == .motionTransfer && !unnamed.referencesAreFrames)
    }
}
