import Foundation
import Testing

@testable import JutsuCore

@Test func jobSpecRoundTripsThroughJSON() throws {
    var spec = makeSpec(mode: .restyle, references: 2, presetID: UUID(), prompt: "rain", resolution: .p1080)
    spec.audio = .fadeOut
    spec.model = .seedance25
    spec.source?.bookmark = Data([1, 2, 3])
    spec.references[1].bookmark = Data([4, 5])
    let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec))
    #expect(decoded == spec)
}

@Test func jobStateRoundTripsThroughJSON() throws {
    for state in [JobState.failed(reason: .message("boom")), .paused(.insufficientFunds), .paused(.byUser), .done] {
        #expect(try JSONDecoder().decode(JobState.self, from: JSONEncoder().encode(state)) == state)
    }
}

@Test func specStoredBeforeBookmarksAndAudioDecodesWithDefaults() throws {
    let json = """
        {"mode": "motionTransfer", "prompt": "", "resolution": "480p", "isDraft": false,
         "source": {"fileURL": "file:///tmp/source.mov", "duration": 60, "pixelSize": {"width": 1280, "height": 720},
                    "range": [0, 10], "allowsUpscale": false},
         "references": [{"fileURL": "file:///tmp/ref0.jpg"}]}
        """
    let decoded = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
    #expect(decoded == makeSpec())
    #expect(decoded.source?.bookmark == nil)
    #expect(decoded.audio == .original)
    #expect(decoded.model == .genjutsu)
    #expect(!decoded.usesUnlimited)
    #expect(decoded.references.map(\.bookmark) == [nil])
}

@Test func missingBookmarkIsLeftOutOfTheJSON() throws {
    let image = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image))
    let keys = try #require(object as? [String: Any]).keys
    #expect(Array(keys) == ["fileURL"])
}

@Test func costDecodesTheOldNumberFormat() throws {
    let usd = #"{"usd":{"_0":3.816,"isEstimate":false}}"#
    let expected = try #require(Decimal(string: "3.816"))
    #expect(try JSONDecoder().decode(Cost.self, from: Data(usd.utf8)) == .usd(expected, isEstimate: false))
    let credits = #"{"credits":{"_0":96,"isEstimate":true}}"#
    #expect(try JSONDecoder().decode(Cost.self, from: Data(credits.utf8)) == .credits(96, isEstimate: true))
}

/// Whole credits stay a number, as every library saved before fractional credits has them.
@Test func wholeCreditsStayANumber() throws {
    let data = try JSONEncoder().encode(Cost.credits(96, isEstimate: true))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    #expect(object["credits"]?["_0"] as? Int == 96)
}

@Test func costStoresTheAmountAsAString() throws {
    let amount = try #require(Decimal(string: "0.318")) * 37
    let data = try JSONEncoder().encode(Cost.usd(amount, isEstimate: true))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    #expect(object["usd"]?["_0"] as? String == "11.766")
}

/// Outside the `@Test` attribute: Swift 6.0.3 on Linux crashes type-checking a closure inside the macro arguments.
private let exactCosts: [Cost] =
    ["0.318", "11.766", "48.96", "0.0000001", "123456789.123456789", "-2.5"]
    .map { Cost.usd(Decimal(string: $0)!, isEstimate: false) }
    + [.credits(500, isEstimate: true), .credits(Decimal(string: "0.5")!, isEstimate: false)]

@Test(arguments: exactCosts)
func costRoundTripsExactly(cost: Cost) throws {
    #expect(try JSONDecoder().decode(Cost.self, from: JSONEncoder().encode(cost)) == cost)
}

@Test func modelLimitsWithoutASourceAreGenjutsus() {
    for mode in Mode.allCases {
        #expect(VideoModel.genjutsu.limits(for: mode) == mode.limits)
    }
    let kling = VideoModel.klingMotionControl.limits(for: .motionTransfer)
    #expect(kling.referenceImages == 1...1)
    #expect(kling.duration == Mode.motionTransfer.limits.duration)
    let seedance = VideoModel.seedance25.limits(for: .motionTransfer)
    #expect(seedance.duration == 4...30)
    #expect(seedance.referenceImages == Mode.motionTransfer.limits.referenceImages)
    #expect(Mode.motionTransfer.limits.duration == Validation.durationRange)
}

@Test func specLimitsFollowItsModel() {
    var spec = makeSpec(mode: .restyle)
    #expect(spec.limits() == Mode.restyle.limits)
    spec.mode = .motionTransfer
    spec.model = .seedance25
    #expect(spec.limits() == VideoModel.seedance25.limits(for: .motionTransfer))
}

@Test func eachModelServesItsModes() {
    #expect(Mode.allCases.filter { VideoModel.genjutsu.serves($0) } == [.motionTransfer, .restyle, .objectSwap])
    #expect(Mode.allCases.filter { VideoModel.seedance25.serves($0) } == [.motionTransfer, .edit, .extend])
    #expect(Mode.allCases.filter { VideoModel.klingMotionControl.serves($0) } == [.motionTransfer])
    #expect(Mode.allCases.filter { $0.defaultModel.serves($0) } == Mode.allCases)
}

/// Edit and Extend have their own Seedance endpoints whatever the media, and Extend's length is the part it adds.
@Test func editAndExtendRunOnTheirOwnEndpoints() {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 10, pixelSize: PixelSize(width: 1280, height: 720),
        range: 2...10)
    let edit = JobSpec(mode: .edit, model: .seedance25, source: source, prompt: "night", resolution: .p720)
    let extend = JobSpec(
        mode: .extend, model: .seedance25, source: source, prompt: "she leaves", resolution: .p720, length: 6)

    #expect(edit.endpointID == "bytedance/seedance-2.5/video-edit")
    #expect(extend.endpointID == "bytedance/seedance-2.5/video-extend")
    #expect(edit.duration == 8)
    #expect(extend.duration == 6)
    #expect(extend.limits().duration == 4...30)
}

/// Jobs stored before Edit and Extend existed decode unchanged, and the new modes round-trip.
@Test func storedModesStillDecode() throws {
    let decoded = try JSONDecoder().decode([Mode].self, from: Data(#"["motionTransfer","restyle","objectSwap"]"#.utf8))
    #expect(decoded == [.motionTransfer, .restyle, .objectSwap])
    let new = try JSONDecoder().decode([Mode].self, from: JSONEncoder().encode([Mode.edit, .extend]))
    #expect(new == [.edit, .extend])
}

@Test func aClipWithoutASourceRoundTripsAndNeedsNoImage() throws {
    let spec = JobSpec(
        mode: .motionTransfer, model: .seedance25, source: nil, prompt: "a fox in the snow", resolution: .p720,
        length: 12, aspectRatio: .portrait)
    #expect(try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec)) == spec)
    #expect(spec.duration == 12)
    #expect(spec.limits().referenceImages == 0...8)
    #expect(VideoModel.allCases.filter(\.makesClipsWithoutSource) == [.seedance25])
}

@Test func aSpecIsNamedByItsSourceElseItsPrompt() {
    #expect(makeSpec().name == "source")
    var spec = JobSpec(mode: .motionTransfer, model: .seedance25, source: nil, resolution: .p720, length: 5)
    #expect(spec.name == "Seedance 2.5")
    spec.prompt = "  A fox runs through fresh snow at dawn, slow motion, golden light\nsecond line"
    #expect(spec.name == "A fox runs through fresh snow at dawn, s…")
    #expect(AspectRatio.portrait.widthOverHeight == 9.0 / 16)
    #expect(AspectRatio.auto.widthOverHeight == nil)
}

@Test func aTitleNamesTheSpecInsteadOfItsSource() {
    var spec = makeSpec()
    spec.title = JobSpec.title(from: "  Knight, take 3 \n  rooftop  \n")
    #expect(spec.title == "Knight, take 3 rooftop")
    #expect(spec.name == "Knight, take 3 rooftop")
    #expect(ExportNaming.baseName(for: spec, presetName: nil).hasPrefix("Knight, take 3 rooftop_00m00.0s"))
    #expect(JobSpec.title(from: String(repeating: "a", count: 200))?.count == JobSpec.maxTitleLength)
    #expect(JobSpec.title(from: " \n ") == nil)
    #expect(JobSpec.title(from: nil) == nil)
}

/// An agent's title names rows, cards and files: no control or bidi-override characters, single spaces.
@Test func aTitleDropsControlAndFormatCharacters() {
    #expect(JobSpec.title(from: "Knight\t\ttake\u{0}3") == "Knight take 3")
    #expect(JobSpec.title(from: "invoice\u{202E}4pm.exe") == "invoice4pm.exe")
    #expect(JobSpec.title(from: "a\u{200B}b \u{2066}c\u{2069}\u{2028}d") == "ab c d")
    #expect(JobSpec.title(from: "\u{202E}\t\u{0}") == nil)
    #expect(JobSpec.title(from: "Family 👨\u{200D}👩\u{200D}👧") == "Family 👨\u{200D}👩\u{200D}👧")
}

@Test func aSpecStoredBeforeTitlesDecodesNamedByItsSource() throws {
    var spec = makeSpec()
    spec.title = "Knight"
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
    #expect(object.removeValue(forKey: "title") as? String == "Knight")

    let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.title == nil)
    #expect(decoded.name == "source")
    #expect(try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec)) == spec)
}

@Test func aSpecStoredBeforeTheModelParametersDecodesWithout() throws {
    let json = #"""
        {"mode": "motionTransfer", "model": "seedance25", "references": [], "prompt": "a fox",
         "resolution": "720p", "isDraft": false, "length": 5}
        """#
    let spec = try JSONDecoder().decode(JobSpec.self, from: Data(json.utf8))
    #expect(spec.bitrate == nil && spec.characterOrientation == nil)
    #expect(!spec.referencesAreFrames && !spec.usesFrames)
    #expect(spec.endpointID == "bytedance/seedance-2.5/text-to-video")
}

@Test func theModelParametersRoundTrip() throws {
    let spec = JobSpec(
        mode: .motionTransfer, model: .seedance25, source: nil,
        references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/start.png"))], resolution: .p1080,
        audio: .generated, length: 6, bitrate: .standard, characterOrientation: .image, referencesAreFrames: true)
    let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec))
    #expect(decoded == spec)
}

/// The references are the start and end frame only on Seedance without a source.
@Test func framesRunOnImageToVideo() {
    let frames = (0..<2).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/frame\($0).png")) }
    var spec = JobSpec(
        mode: .motionTransfer, model: .seedance25, source: nil, references: frames, resolution: .p720, length: 5,
        referencesAreFrames: true)
    #expect(spec.usesFrames)
    #expect(spec.endpointID == "bytedance/seedance-2.5/image-to-video")
    #expect(spec.limits().referenceImages == 1...2)

    spec.source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 10, pixelSize: PixelSize(width: 1280, height: 720),
        range: 0...5)
    #expect(!spec.usesFrames)
    #expect(spec.endpointID == "bytedance/seedance-2.5/reference-to-video")
    spec.source = nil
    spec.model = .klingMotionControl
    #expect(!spec.usesFrames)
}
