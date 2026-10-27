import Foundation

/// One subtitle on screen: up to two lines from `start` to `end`, in seconds from the start of the video.
public struct SubtitleCue: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    /// Its lines, joined by "\n".
    public var text: String

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    /// The lines that show, without empty ones.
    public var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Timed words into subtitle cues by the usual rules: at most two lines of 42 characters, each cue on screen 1 to 7
/// seconds, split at sentence ends and pauses, never overlapping.
///
/// A cue closes when the next word wouldn't fit in two lines or would keep it over 7 seconds, after a pause of half a
/// second once it has shown for a second (or after a pause of 1.5 seconds at any time), and at a sentence end once it
/// holds half a line. A word whose end runs on into a pause is cut back first, so the pause counts. A cue of one word
/// after a long pause joins a neighbour where both fit in one cue. Then short cues are stretched to a second where the
/// next one leaves room, and no cue runs into the next. Words are joined by the language's separator
/// (`WordSpacing.separator`): a space, or nothing in a language written without spaces.
public enum CueBuilder {
    public static let maxLineLength = 42
    public static let minDuration: TimeInterval = 1
    public static let maxDuration: TimeInterval = 7
    public static let pause: TimeInterval = 0.5
    /// A pause this long closes a cue that has shown for less than `minDuration`, and makes a lone word after it a
    /// candidate to join a neighbour.
    public static let longPause: TimeInterval = 1.5
    static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    public static func cues(from words: [TimedWord], separator: String = " ") -> [SubtitleCue] {
        let words = capped(words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        var groups: [[TimedWord]] = []
        var current: [TimedWord] = []
        for word in words {
            if let first = current.first, let last = current.last,
                closes(current, first, last, before: word, separator: separator)
            {
                groups.append(current)
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return timed(joiningLoneWords(groups, separator: separator), separator: separator)
    }

    /// The longest a word is taken to last: about a syllable's time per two characters.
    static func longestDuration(of word: String) -> TimeInterval {
        0.3 + 0.08 * Double(word.count)
    }

    /// Ends cut back to `longestDuration`: a model often stretches a word over the pause after it.
    static func capped(_ words: [TimedWord]) -> [TimedWord] {
        words.map { word in
            var word = word
            word.end = max(word.start, min(word.end, word.start + longestDuration(of: word.text)))
            return word
        }
    }

    private static func closes(
        _ current: [TimedWord], _ first: TimedWord, _ last: TimedWord, before word: TimedWord, separator: String
    )
        -> Bool
    {
        let gap = word.start - last.end
        let tooLong = word.end - first.start > maxDuration
        let noFit = wrap(current.map(\.text) + [word.text], separator: separator) == nil
        let sentence =
            last.text.last.map(sentenceEnds.contains) == true
            && current.map(\.text).joined(separator: separator).count >= maxLineLength / 2
        let paused = gap >= pause && (last.end - first.start >= minDuration || gap >= longPause)
        return paused || tooLong || noFit || sentence
    }

    /// A one-word cue after a long pause joins the next cue, or else the one before, when the two fit in one.
    private static func joiningLoneWords(_ groups: [[TimedWord]], separator: String) -> [[TimedWord]] {
        var groups = groups
        var index = 0
        while index < groups.count {
            let lone = groups[index]
            let previousEnd = index > 0 ? groups[index - 1].last?.end ?? 0 : 0
            let afterPause = lone[0].start - previousEnd >= longPause
            guard lone.count == 1, afterPause, groups.count > 1 else {
                index += 1
                continue
            }
            if index + 1 < groups.count, fits(lone + groups[index + 1], separator: separator) {
                groups[index + 1] = lone + groups[index + 1]
                groups.remove(at: index)
            } else if index > 0, fits(groups[index - 1] + lone, separator: separator) {
                groups[index - 1] += lone
                groups.remove(at: index)
            } else {
                index += 1
            }
        }
        return groups
    }

    private static func fits(_ words: [TimedWord], separator: String) -> Bool {
        guard let first = words.first, let last = words.last else { return true }
        return last.end - first.start <= maxDuration && wrap(words.map(\.text), separator: separator) != nil
    }

    private static func timed(_ groups: [[TimedWord]], separator: String) -> [SubtitleCue] {
        var cues = groups.compactMap { group -> SubtitleCue? in
            guard let first = group.first, let last = group.last else { return nil }
            let words = group.map(\.text)
            let lines = wrap(words, separator: separator) ?? [words.joined(separator: separator)]
            return SubtitleCue(start: first.start, end: last.end, text: lines.joined(separator: "\n"))
        }
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : cues[index].end + minDuration
            if cues[index].end - cues[index].start < minDuration {
                cues[index].end = min(cues[index].start + minDuration, next)
            }
            cues[index].end = max(cues[index].start, min(cues[index].end, next))
        }
        return cues
    }

    /// The words on one line, or on two of about the same length; `nil` when they don't fit. A single word too long
    /// for a line keeps a line of its own.
    public static func wrap(_ words: [String], separator: String = " ") -> [String]? {
        let joined = { (words: [String]) in words.joined(separator: separator) }
        let text = joined(words)
        if text.count <= maxLineLength || words.count == 1 { return [text] }
        var best: (score: Int, lines: [String])?
        for split in 1..<words.count {
            let first = joined(Array(words[..<split]))
            let second = joined(Array(words[split...]))
            guard first.count <= maxLineLength, second.count <= maxLineLength else { continue }
            let score = abs(first.count - second.count)
            if best.map({ score < $0.score }) ?? true { best = (score, [first, second]) }
        }
        return best?.lines
    }
}
