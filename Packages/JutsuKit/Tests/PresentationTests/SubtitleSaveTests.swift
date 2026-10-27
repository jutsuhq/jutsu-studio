import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct SubtitleSaveTests {
    let opened = Subtitles(
        transcript: Transcript(
            language: "en-US", model: .transcriber, revision: "1",
            words: [TimedWord(text: "Hello", start: 0, end: 0.5)]))

    @Test func doneSavesOnlyOverWhatTheEditorOpenedWith() {
        #expect(SubtitleSave.decide(opened: opened, stored: .some(opened)) == .save)
        var remade = opened
        remade.cues = [SubtitleCue(start: 0, end: 2, text: "Hello again")]
        #expect(SubtitleSave.decide(opened: opened, stored: .some(remade)) == .changedMeanwhile)
        #expect(SubtitleSave.decide(opened: opened, stored: .some(nil)) == .changedMeanwhile)
        #expect(SubtitleSave.decide(opened: opened, stored: nil) == .versionGone)
    }
}
