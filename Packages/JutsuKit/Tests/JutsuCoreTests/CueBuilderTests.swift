import Foundation
import Testing

@testable import JutsuCore

@Suite struct CueBuilderTests {
    /// Words of `text` spoken one after another from `start`, each `step` long with no gap.
    private func spoken(_ text: String, from start: TimeInterval = 0, step: TimeInterval = 0.3) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { offset, word in
            TimedWord(text: String(word), start: start + Double(offset) * step, end: start + Double(offset + 1) * step)
        }
    }

    private func lines(_ cues: [SubtitleCue]) -> [[String]] { cues.map(\.lines) }

    @Test func aLongStreamKeepsEveryRule() {
        let sentence = "the quick brown fox jumps over the lazy dog while the band plays on and on"
        let words = spoken(Array(repeating: sentence, count: 12).joined(separator: " "), step: 0.25)
        let cues = CueBuilder.cues(from: words)

        #expect(cues.count > 10)
        for cue in cues {
            #expect(cue.lines.count <= 2)
            #expect(cue.lines.allSatisfy { $0.count <= CueBuilder.maxLineLength })
            #expect(cue.end - cue.start <= CueBuilder.maxDuration)
            #expect(cue.end - cue.start >= CueBuilder.minDuration - 1e-9)
        }
        for (cue, next) in zip(cues, cues.dropFirst()) { #expect(cue.end <= next.start) }
        #expect(cues.flatMap(\.lines).joined(separator: " ").split(separator: " ").count == words.count)
    }

    @Test func aSentenceEndClosesACueThatHoldsHalfALine() {
        let cues = CueBuilder.cues(from: spoken("This sentence is long enough here. And then another one starts."))
        #expect(lines(cues) == [["This sentence is long enough here."], ["And then another one starts."]])

        let short = CueBuilder.cues(from: spoken("Hi there. How are you doing today?"))
        #expect(lines(short) == [["Hi there. How are you doing today?"]])
    }

    @Test func aPauseClosesACueOnceItHasShownForASecond() {
        let cues = CueBuilder.cues(from: spoken("one two three four", step: 0.3) + spoken("five six", from: 1.9))
        #expect(lines(cues) == [["one two three four"], ["five six"]])

        // Shown for 0.6 s: a pause under 1.5 s doesn't close it.
        let early = CueBuilder.cues(from: spoken("one two", step: 0.3) + spoken("three four", from: 1.4))
        #expect(lines(early) == [["one two three four"]])
    }

    @Test func aWordThatRunsOnIntoAPauseIsCutBack() {
        // "four" claims to last until 3.4 s; cut back, the 1.9 s pause before "five" closes the cue there.
        var words = spoken("one two three four", step: 0.3)
        words[3].end = 3.4
        let cues = CueBuilder.cues(from: words + spoken("five six", from: 3.5))

        #expect(lines(cues) == [["one two three four"], ["five six"]])
        #expect(cues[0].end < 2)
    }

    @Test func aLoneWordAfterALongPauseJoinsTheNextCue() {
        // "Absolutely" shows for over a second, so the pause after it closes its cue; alone, it joins the next.
        let words =
            spoken("This first sentence is long enough.")
            + [TimedWord(text: "Absolutely", start: 6, end: 7.1)]
            + spoken("we start again", from: 7.7)
        let cues = CueBuilder.cues(from: words)
        #expect(lines(cues) == [["This first sentence is long enough."], ["Absolutely we start again"]])
    }

    @Test func aLoneWordJoinsTheCueBeforeWhenTheNextIsFull() {
        let full = "this next cue is already filled to the brim with words and more words on it"
        let words =
            spoken("Short start")
            + [TimedWord(text: "well", start: 2.5, end: 2.8)]
            + spoken(full, from: 4.4, step: 0.4)
        let cues = CueBuilder.cues(from: words)
        #expect(cues.first?.lines == ["Short start well"])
    }

    @Test func shortCuesStretchToASecondWithoutRunningIntoTheNext() {
        let cues = CueBuilder.cues(
            from: spoken("This is a long first sentence.", step: 0.1) + spoken("And another thing here.", from: 0.8))
        #expect(cues.count == 2)
        #expect(cues[0].end == 0.8)

        let last = CueBuilder.cues(from: [TimedWord(text: "Bye.", start: 5, end: 5.2)])
        #expect(last.first.map { $0.end - $0.start } == 1)
    }

    @Test func wrappingBalancesTwoLinesAndRefusesThree() {
        let words = "a quick brown fox jumps over the lazy dog and keeps on running far".split(separator: " ")
            .map(String.init)
        let lines = CueBuilder.wrap(words)
        #expect(lines?.count == 2)
        #expect(lines.map { abs($0[0].count - $0[1].count) <= 6 } == true)
        #expect(CueBuilder.wrap(Array(repeating: "wordy", count: 20)) == nil)
        let long = String(repeating: "x", count: 50)
        #expect(CueBuilder.wrap([long]) == [long])
    }

    @Test func subtitleFilesAreTimedToTheMillisecond() {
        let cues = [
            SubtitleCue(start: 1.2, end: 3.4567, text: "Hello there,\nfriend."),
            SubtitleCue(start: 3.5, end: 3.9, text: "  \n"),
            SubtitleCue(start: 3661.0004, end: 3662, text: "A --> B"),
        ]
        #expect(
            SubtitleFormat.srt.text(of: cues)
                == "1\n00:00:01,200 --> 00:00:03,457\nHello there,\nfriend.\n\n2\n01:01:01,000 --> 01:01:02,000\nA → B\n"
        )
        #expect(
            SubtitleFormat.vtt.text(of: cues)
                == "WEBVTT\n\n00:00:01.200 --> 00:00:03.457\nHello there,\nfriend.\n\n01:01:01.000 --> 01:01:02.000\nA → B\n"
        )
    }

    @Test func editingMergesSplitsAndFindsTheCueOnScreen() throws {
        let transcript = Transcript(language: "en-US", model: .transcriber, revision: "1", words: [])
        let a = SubtitleCue(start: 0, end: 2, text: "Hello there")
        let b = SubtitleCue(start: 2, end: 4, text: "my good friend")
        var subtitles = Subtitles(transcript: transcript, cues: [a, b])

        #expect(subtitles.cue(at: 2.5)?.id == b.id)
        #expect(subtitles.cue(at: 5) == nil)
        #expect(subtitles.canMerge(a.id))
        #expect(!subtitles.canMerge(b.id))
        subtitles.mergeWithNext(a.id)
        #expect(subtitles.cues.map(\.text) == ["Hello there my good friend"])
        #expect(subtitles.cues[0].end == 4)

        subtitles.split(a.id)
        #expect(subtitles.cues.map(\.text) == ["Hello there", "my good friend"])
        #expect(subtitles.cues[0].end == subtitles.cues[1].start)
        #expect(abs(subtitles.cues[0].end - 4 * 11 / 25) < 1e-9)

        subtitles.setText("Hi there", of: a.id)
        #expect(subtitles.cues[0].text == "Hi there")
        let one = try #require(subtitles.cues.last)
        subtitles.setText("friend", of: one.id)
        #expect(!subtitles.canSplit(one.id))
    }

    @Test func subtitlesBuildTheirCuesFromTheTranscript() {
        let transcript = Transcript(
            language: "en-US", model: .transcriber, revision: "1", words: spoken("Hello there."))
        #expect(Subtitles(transcript: transcript).cues.map(\.text) == ["Hello there."])
    }

    /// Runs as a model writes them, each `step` long.
    private func runs(_ texts: [String], step: TimeInterval = 0.3) -> [TimedWord] {
        texts.enumerated().map { offset, text in
            TimedWord(text: text, start: Double(offset) * step, end: Double(offset + 1) * step)
        }
    }

    @Test func runsWithoutALeadingSpaceJoinTheWordBeforeInASpacedLanguage() {
        var words: [TimedWord] = []
        WordSpacing.append(runs(["Hello", ",", " world", "s", " again."]), to: &words, language: "en-US")

        #expect(words.map(\.text) == ["Hello,", "worlds", "again."])
        #expect(words[1].start == 0.6 && words[1].end == 1.2)
    }

    @Test func aLanguageWithoutSpacesKeepsEachRunAsAWordAndJoinsWithNothing() throws {
        var words: [TimedWord] = []
        let spoken = ["今日", "は", "とても", "いい", "天気", "です", "ね", "。", "明日", "も", "晴れ", "る", "でしょう", "か", "？"]
        WordSpacing.append(runs(spoken), to: &words, language: "ja-JP")

        #expect(words.count == spoken.count - 2)
        #expect(words[6].text == "ね。")
        let transcript = Transcript(language: "ja-JP", model: .transcriber, revision: "1", words: words)
        #expect(transcript.text == "今日はとてもいい天気ですね。明日も晴れるでしょうか？")
        var subtitles = Subtitles(transcript: transcript)
        #expect(subtitles.cues.map(\.text) == ["今日はとてもいい天気ですね。明日も晴れるでしょうか？"])

        let cue = try #require(subtitles.cues.first)
        #expect(subtitles.canSplit(cue.id))
        subtitles.split(cue.id)
        #expect(subtitles.cues.count == 2)
        #expect(subtitles.cues.map(\.text).joined() == transcript.text)
        #expect(subtitles.cues.allSatisfy { !$0.text.contains(" ") })
        subtitles.mergeWithNext(subtitles.cues[0].id)
        #expect(subtitles.cues.map(\.text) == [transcript.text])
        #expect(WordSpacing.separator(for: "zh-Hans-CN") == "" && WordSpacing.separator(for: "yue") == "")
        #expect(WordSpacing.separator(for: "de-DE") == " ")
    }
}

@Suite struct DeliverySubtitlesTests {
    private func set(_ outputs: [DeliveryOutput]) -> DeliverySet {
        let item = DeliverySet.Item(
            reference: MaterialReference(materialID: UUID(), versionID: UUID()), kind: .video, name: "clip")
        return DeliverySet(name: "Set", items: [item], outputs: outputs)
    }

    @Test func subtitleFilesNeedFreeNamesBesideTheVideo() {
        let output = DeliveryOutput(preset: .video(.editingH264), subtitles: .files)
        let free = DeliveryPlan.tasks(for: set([output]), scope: .all) { _ in false }
        let base = (free[0].fileName as NSString).deletingPathExtension

        let tasks = DeliveryPlan.tasks(for: set([output]), scope: .all) { $0 == "\(base).vtt" }
        #expect(tasks.count == 1)
        #expect(tasks[0].fileName != free[0].fileName)
        #expect(DeliveryPlan.names(tasks[0].fileName, output).count == 3)
        #expect(DeliveryPlan.names("a.mp4", DeliveryOutput(preset: .video(.editingH264))) == ["a.mp4"])
    }

    @Test func burningInNamesTheOutputAndOldOutputsStillDecode() throws {
        let burned = DeliveryOutput(preset: .video(.editingH264), subtitles: .burnIn)
        #expect(burned.summary == "editingH264-subtitled")
        #expect(burned.subtitleFormats.isEmpty)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(burned)) as? [String: Any])
        json.removeValue(forKey: "subtitles")
        let old = try JSONDecoder().decode(DeliveryOutput.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.subtitles == nil)
    }
}
