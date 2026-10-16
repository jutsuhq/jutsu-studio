import Foundation
import Testing

@testable import JutsuCore

private func plan(
    _ option: AudioOption = .original, range: ClosedRange<TimeInterval> = 2...12, sourceAudioEnd: TimeInterval? = 60,
    resultDuration: TimeInterval = 10, resultHasAudio: Bool = false
) -> AudioPlan {
    AudioPlan.make(
        option: option, sourceRange: range, sourceAudioEnd: sourceAudioEnd, resultDuration: resultDuration,
        resultHasAudio: resultHasAudio)
}

@Suite struct AudioPlanTests {
    @Test func silentResultGetsTheSourceRange() {
        #expect(plan() == .addSource(range: 2...12, fadeOut: nil))
    }

    @Test func resultWithItsOwnSoundIsKept() {
        #expect(plan(resultHasAudio: true) == .keep)
        #expect(plan(.fadeOut, resultHasAudio: true) == .keep)
    }

    /// The model was asked for the sound, so even a result that came back silent doesn't get the source's.
    @Test func generatedSoundIsLeftAsItCame() {
        #expect(plan(.generated, resultHasAudio: true) == .keep)
        #expect(plan(.generated, resultHasAudio: false) == .keep)
    }

    @Test func silentSourceLeavesTheResultAlone() {
        #expect(plan(sourceAudioEnd: nil) == .keep)
        #expect(plan(.fadeOut, sourceAudioEnd: nil) == .keep)
    }

    @Test func muteStripsSoundOnlyWhenThereIsSome() {
        #expect(plan(.mute, resultHasAudio: true) == .removeAudio)
        #expect(plan(.mute) == .keep)
        #expect(plan(.mute, sourceAudioEnd: nil, resultHasAudio: true) == .removeAudio)
    }

    @Test func shorterResultCutsTheAudio() {
        #expect(plan(resultDuration: 7.5) == .addSource(range: 2...9.5, fadeOut: nil))
    }

    @Test func longerResultIsNotStretched() {
        #expect(plan(resultDuration: 14) == .addSource(range: 2...12, fadeOut: nil))
    }

    @Test func audioTrackEndingEarlyLimitsTheRange() {
        #expect(plan(sourceAudioEnd: 8) == .addSource(range: 2...8, fadeOut: nil))
        #expect(plan(sourceAudioEnd: 2) == .keep)
        #expect(plan(sourceAudioEnd: 1) == .keep)
    }

    @Test func emptyResultIsKept() {
        #expect(plan(resultDuration: 0) == .keep)
    }

    @Test func fadeOutCoversTheLastSecondOfTheAudio() {
        #expect(plan(.fadeOut) == .addSource(range: 2...12, fadeOut: 9...10))
        #expect(plan(.fadeOut, resultDuration: 6) == .addSource(range: 2...8, fadeOut: 5...6))
    }

    @Test func fadeOutOfVeryShortAudioCoversAllOfIt() {
        #expect(plan(.fadeOut, sourceAudioEnd: 2.5) == .addSource(range: 2...2.5, fadeOut: 0...0.5))
    }

    @Test func negativeStartIsClamped() {
        #expect(plan(range: -1...5, resultDuration: 10) == .addSource(range: 0...5, fadeOut: nil))
    }
}
