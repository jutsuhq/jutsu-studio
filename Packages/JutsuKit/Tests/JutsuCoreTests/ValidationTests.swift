import Foundation
import Testing

@testable import JutsuCore

@Test func validSpecsHaveNoIssues() {
    #expect(Validation.check(makeSpec(mode: .motionTransfer)).isEmpty)
    #expect(Validation.check(makeSpec(mode: .objectSwap)).isEmpty)
    #expect(Validation.check(makeSpec(mode: .restyle, references: 0, presetID: UUID())).isEmpty)
}

@Test(arguments: [4.0, 30.0, 3.999_999_9, 30.000_000_1])
func durationBoundsAreInclusive(duration: TimeInterval) {
    #expect(Validation.check(makeSpec(duration: duration)).isEmpty)
}

@Test func durationOutsideFourToThirtySeconds() {
    #expect(Validation.check(makeSpec(duration: 3.9)) == [.durationTooShort(3.9)])
    #expect(Validation.check(makeSpec(duration: 30.1)) == [.durationTooLong(30.1)])
}

@Test(arguments: [Mode.motionTransfer, .objectSwap])
func referenceCountsForMotionAndSwap(mode: Mode) {
    #expect(Validation.check(makeSpec(mode: mode, references: 0)) == [.tooFewReferences(minimum: 1)])
    #expect(Validation.check(makeSpec(mode: mode, references: 8)).isEmpty)
    #expect(Validation.check(makeSpec(mode: mode, references: 9)) == [.tooManyReferences(maximum: 8)])
}

@Test func referenceCountsForRestyle() {
    #expect(Validation.check(makeSpec(mode: .restyle, references: 5, presetID: UUID())).isEmpty)
    #expect(
        Validation.check(makeSpec(mode: .restyle, references: 6, presetID: UUID())) == [.tooManyReferences(maximum: 5)])
}

@Test func restyleRequiresAPreset() {
    #expect(Validation.check(makeSpec(mode: .restyle, references: 0)) == [.presetRequired])
}

@Test func objectSwapNeedsEnoughPixelsUnlessUpscaleIsAllowed() {
    let small = PixelSize(width: 720, height: 480)
    #expect(Validation.check(makeSpec(mode: .objectSwap, size: small)) == [.frameTooSmall(small)])
    #expect(Validation.check(makeSpec(mode: .objectSwap, size: small, allowsUpscale: true)).isEmpty)
    #expect(Validation.check(makeSpec(mode: .objectSwap, size: PixelSize(width: 640, height: 640))).isEmpty)
    #expect(Validation.check(makeSpec(mode: .motionTransfer, size: small)).isEmpty)
}

@Test func promptLengthCountsUnicodeScalars() {
    #expect(Validation.check(makeSpec(prompt: String(repeating: "a", count: 10_000))).isEmpty)
    #expect(
        Validation.check(makeSpec(prompt: String(repeating: "a", count: 10_001))) == [.promptTooLong(length: 10_001)])
    // One grapheme, two scalars: 5 001 flags are 10 002 scalars.
    #expect(
        Validation.check(makeSpec(prompt: String(repeating: "🇯🇵", count: 5_001))) == [.promptTooLong(length: 10_002)])
}

@Test func allIssuesAreReportedTogether() {
    let spec = makeSpec(mode: .restyle, duration: 2, references: 7, prompt: String(repeating: "a", count: 10_001))
    #expect(
        Validation.check(spec) == [
            .durationTooShort(2), .tooManyReferences(maximum: 5), .presetRequired, .promptTooLong(length: 10_001),
        ])
}

@Test(arguments: [
    (720, 480, 784, 524), (640, 360, 854, 480), (480, 480, 640, 640), (1280, 720, 1280, 720), (640, 640, 640, 640),
])
func upscaledSize(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) {
    let size = Validation.upscaledSize(width: width, height: height)
    #expect(size == PixelSize(width: expectedWidth, height: expectedHeight))
    #expect(size.pixelCount >= Validation.objectSwapMinimumPixels)
    #expect(size.width % 2 == 0 && size.height % 2 == 0)
}

private func spec(duration: TimeInterval, range: ClosedRange<TimeInterval>, size: PixelSize? = nil) -> JobSpec {
    var spec = makeSpec()
    spec.source?.duration = duration
    spec.source?.range = range
    if let size { spec.source?.pixelSize = size }
    return spec
}

@Test(arguments: [
    (60.0, 50.0...70.0), (60.0, -1.0...10.0), (.nan, 0.0...10.0), (.infinity, 0.0...10.0),
    (.infinity, ClosedRange(uncheckedBounds: (TimeInterval.infinity, .infinity))), (60.0, 0.0...TimeInterval.infinity),
])
func selectionMustBeFiniteAndInsideTheSource(duration: TimeInterval, range: ClosedRange<TimeInterval>) {
    #expect(Validation.check(spec(duration: duration, range: range)) == [.selectionOutsideSource])
}

@Test func selectionMayEndAtTheSourceEnd() {
    #expect(Validation.check(spec(duration: 10, range: 0...10.000_000_1)).isEmpty)
}

@Test(arguments: [PixelSize(width: 0, height: 720), PixelSize(width: -1280, height: -720)])
func frameSidesMustBePositive(size: PixelSize) {
    #expect(Validation.check(spec(duration: 60, range: 0...10, size: size)) == [.invalidFrameSize(size)])
    var swap = spec(duration: 60, range: 0...10, size: size)
    swap.mode = .objectSwap
    #expect(Validation.check(swap) == [.invalidFrameSize(size)])
}

@Test func pixelCountNeverTraps() {
    #expect(PixelSize(width: -1280, height: -720).pixelCount == 0)
    #expect(PixelSize(width: .max, height: 2).pixelCount == .max)
    #expect(PixelSize(width: 1280, height: 720).pixelCount == 921_600)
}

private func clipWithoutSource(
    model: VideoModel = .seedance25, prompt: String = "a fox in the snow", references: Int = 0, length: TimeInterval = 5
) -> JobSpec {
    JobSpec(
        mode: .motionTransfer, model: model, source: nil,
        references: (0..<references).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref\($0).png")) },
        prompt: prompt, resolution: .p720, length: length, aspectRatio: .landscape)
}

@Test func seedanceMakesAClipWithoutASourceFromAPromptOrAnImage() {
    #expect(Validation.check(clipWithoutSource()).isEmpty)
    #expect(Validation.check(clipWithoutSource(prompt: "", references: 1)).isEmpty)
    #expect(Validation.check(clipWithoutSource(prompt: " \n")) == [.promptRequired])
    #expect(Validation.check(clipWithoutSource(references: 9)) == [.tooManyReferences(maximum: 8)])
}

@Test func aClipWithoutASourceKeepsToTheModelsLength() {
    #expect(Validation.check(clipWithoutSource(length: 30)).isEmpty)
    #expect(Validation.check(clipWithoutSource(length: 3)) == [.durationTooShort(3)])
    #expect(Validation.check(clipWithoutSource(length: 31)) == [.durationTooLong(31)])
}

@Test(arguments: [VideoModel.genjutsu, .klingMotionControl])
func otherModelsNeedASource(model: VideoModel) {
    #expect(Validation.check(clipWithoutSource(model: model)).contains(.sourceRequired))
}

private func videoOperation(_ mode: Mode, prompt: String = "make it night", selection: TimeInterval = 8) -> JobSpec {
    var spec = makeSpec(mode: mode, duration: selection, references: 0, prompt: prompt)
    spec.model = .seedance25
    if mode == .extend { spec.length = 5 }
    return spec
}

@Test(arguments: [Mode.edit, .extend])
func editAndExtendNeedASourceAndAPrompt(mode: Mode) {
    #expect(Validation.check(videoOperation(mode)).isEmpty)
    #expect(Validation.check(videoOperation(mode, prompt: " \n")) == [.promptRequired])
    var withoutSource = videoOperation(mode)
    withoutSource.source = nil
    #expect(Validation.check(withoutSource).contains(.sourceRequired))
}

@Test func extendChecksTheSelectionAndTheAddedLength() {
    #expect(Validation.check(videoOperation(.extend, selection: 31)) == [.durationTooLong(31)])
    var spec = videoOperation(.extend)
    spec.length = 3
    #expect(Validation.check(spec) == [.durationTooShort(3)])
    spec.length = nil
    #expect(Validation.check(spec) == [.durationTooShort(0)])
}
