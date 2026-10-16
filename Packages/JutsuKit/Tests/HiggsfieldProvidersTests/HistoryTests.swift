import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    @Suite struct History {
        static let generations = tool(
            "show_generations", "Show the user's generations", ["type", "only_completed", "size", "cursor"])

        @Test func recordedPageMapsToAnObjectSwap() async throws {
            let recorded = try RecordedGenerations.value()
            let (provider, stub) = Provider.provider(tools: Provider.fullSet + [Self.generations]) { name, _ in
                name == "show_generations" ? recorded : [:]
            }

            let page = try await provider.history(after: nil)
            let next = try #require(page.nextCursor)
            _ = try await provider.history(after: next)

            let item = try #require(page.items.first)
            #expect(item.id == "<job id>")
            #expect(item.mode == .objectSwap && item.model == .genjutsu)
            #expect(item.createdAt == Date(timeIntervalSince1970: 1_791_032_606.742653))
            #expect(!item.isLiked)
            #expect(item.duration == 8)
            #expect(item.pixelSize == PixelSize(width: 1080, height: 1920))
            #expect(item.resolution == .p720)
            #expect(item.prompt == "<1712 characters>")
            #expect(item.inputs.video?.id == "<media id>")
            #expect(item.inputs.images.count == 3)
            #expect(item.outputURL.host == "d8j0ntlcm91z4.cloudfront.net")
            let arguments = Provider.calls(stub).filter { $0["name"] == "show_generations" }.map { $0["arguments"] }
            #expect(arguments.first == ["type": "video", "only_completed": true, "size": 24])
            #expect(arguments.last??["cursor"] == "<cursor; value not recorded>")
        }
    }
}

private let video = PastMedia(role: .video, id: "video-1", url: URL(string: "https://cdn.example/in.mp4"))
private let image = PastMedia(role: .image, id: "image-1", url: URL(string: "https://cdn.example/a.png"))

private func generation(
    _ model: String, type: String = "video", status: String = "completed", media: [PastMedia] = [video, image],
    output: URL? = URL(string: "https://cdn.example/out.mp4")
) -> PastGeneration {
    PastGeneration(
        id: "job-1", type: type, status: status, model: model, createdAt: Date(timeIntervalSince1970: 0),
        outputURL: output, width: 720, height: 1280, duration: 6, prompt: "dance", resolution: "720p", media: media)
}

struct HistoryKind: Hashable, Sendable {
    var mode: Mode
    var model: VideoModel
}

private let mappedGenerations: [(PastGeneration, HistoryKind?)] = [
    (generation("hf_mult_motion_control"), HistoryKind(mode: .motionTransfer, model: .genjutsu)),
    (generation("hf_mult_replace_object"), HistoryKind(mode: .objectSwap, model: .genjutsu)),
    (generation("kling3_0_motion_control"), HistoryKind(mode: .motionTransfer, model: .klingMotionControl)),
    (generation("seedance_2_5"), HistoryKind(mode: .motionTransfer, model: .seedance25)),
    (generation("seedance_2_5", media: [image]), HistoryKind(mode: .motionTransfer, model: .seedance25)),
    (generation("seedance_2_5", media: []), HistoryKind(mode: .motionTransfer, model: .seedance25)),
    (generation("kling3_0_motion_control", media: [image]), nil),
    (generation("hf_mult_motion_control", media: [image]), nil),
    (generation("seedream_5_0_flash", type: "image"), nil),
    (generation("kling3_0"), nil),
    (generation("veo3_1", media: []), nil),
    // A Style job is `model: "restyle"` (live run, 2026-10-15); the IDs guessed before don't count.
    (generation("restyle"), HistoryKind(mode: .restyle, model: .genjutsu)),
    (generation("restyle", media: [image]), HistoryKind(mode: .restyle, model: .genjutsu)),
    (generation("hf_mult_restyle"), nil),
    (generation("genjutsu_style", media: [video]), nil),
    (generation("higgsfield/genjutsu/restyle/v1.0"), nil),
    (generation("Restyle"), nil),
    // Still running, a Style job is `type: "image"`; only a completed video is kept.
    (generation("restyle", type: "image", status: "in_progress"), nil),
    (generation("restyle", status: "in_progress"), nil),
    (generation("restyle", type: "image"), nil),
    (generation("restyle", output: URL(string: "http://cdn.example/out.mp4")), nil),
    (generation("hf_mult_motion_control", type: "image"), nil),
    (generation("hf_mult_motion_control", status: "in_progress"), nil),
    (generation("hf_mult_motion_control", output: nil), nil),
    (generation("hf_mult_motion_control", media: [PastMedia(role: .video, id: "video-1", url: nil)]), nil),
    (generation("hf_mult_motion_control", output: URL(string: "file:///Users/me/Movies/out.mp4")), nil),
    (generation("hf_mult_motion_control", output: URL(string: "http://cdn.example/out.mp4")), nil),
    (
        generation(
            "hf_mult_motion_control",
            media: [PastMedia(role: .video, id: "video-1", url: URL(string: "file:///Users/me/Movies/x.mov"))]),
        nil
    ),
]

@Test(arguments: mappedGenerations)
func historyKeepsOnlyVideosOfTheAppsModels(generation: PastGeneration, kind: HistoryKind?) {
    #expect(HistoryMapping.item(generation).map { HistoryKind(mode: $0.mode, model: $0.model) } == kind)
}

@Test func aStyleRunIsImportedAsARestyleThatNeedsAStyleToRunAgain() throws {
    let spec = try #require(HistoryMapping.item(generation("restyle"))).spec()

    #expect(spec.mode == .restyle && spec.model == .genjutsu)
    #expect(spec.source?.fileURL == video.url)
    #expect(Validation.check(spec).contains(.presetRequired))
}

@Test func historyInputsBecomeAJobThatReusesTheMedia() throws {
    let item = try #require(HistoryMapping.item(generation("hf_mult_motion_control", media: [image, video, image])))
    let spec = item.spec(sourceDuration: 12.5, sourceSize: PixelSize(width: 1920, height: 1080))

    let videoURL = try #require(video.url)
    #expect(item.inputs.video == RemoteAsset(url: videoURL, id: "video-1"))
    #expect(item.inputs.images.map(\.id) == ["image-1", "image-1"])
    #expect(spec.remoteInputs == item.inputs)
    #expect(spec.source?.fileURL == video.url)
    #expect(spec.source?.range == 0...12.5)
    #expect(spec.source?.pixelSize == PixelSize(width: 1920, height: 1080))
    #expect(spec.references.map(\.fileURL) == [image.url, image.url].compactMap { $0 })
    #expect(spec.prompt == "dance" && spec.resolution == .p720 && !spec.isDraft)
}

@Test func aSeedanceClipMadeWithoutAVideoKeepsItsLength() throws {
    let item = try #require(HistoryMapping.item(generation("seedance_2_5", media: [image])))
    let spec = item.spec()

    #expect(spec.source == nil)
    #expect(spec.length == 6)
    #expect(spec.duration == 6)
    #expect(spec.references.map(\.fileURL) == [image.url].compactMap { $0 })
    #expect(Validation.check(spec).isEmpty)
}

@Test func historyCursorRoundTripsAsJSON() throws {
    let value: JSONValue = ["after": "abc", "offset": 24]
    let cursor = try #require(HistoryMapping.cursor(value))
    #expect(HistoryMapping.cursorValue(cursor) == value)
    #expect(HistoryMapping.cursorValue(try #require(HistoryMapping.cursor("opaque"))) == "opaque")
}
