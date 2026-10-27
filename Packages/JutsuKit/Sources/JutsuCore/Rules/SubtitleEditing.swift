import Foundation

/// The subtitle editor's changes to a version's cues: text, merging a cue with the next, and splitting one in two.
/// Times stay within the cues', so cues never overlap. In a language written without spaces, a cue splits between any
/// two characters.
extension Subtitles {
    public mutating func setText(_ text: String, of id: UUID) {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[index].text = text
    }

    /// Whether the cue and the next one fit in one cue: two lines, at most `CueBuilder.maxDuration`.
    public func canMerge(_ id: UUID) -> Bool {
        guard let index = cues.firstIndex(where: { $0.id == id }), index + 1 < cues.count else { return false }
        let next = cues[index + 1]
        return next.end - cues[index].start <= CueBuilder.maxDuration
            && CueBuilder.wrap(units(of: cues[index]) + units(of: next), separator: separator) != nil
    }

    /// The cue and the next one as one, its words wrapped again.
    public mutating func mergeWithNext(_ id: UUID) {
        guard canMerge(id), let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let next = cues.remove(at: index + 1)
        let words = units(of: cues[index]) + units(of: next)
        cues[index].end = next.end
        cues[index].text =
            (CueBuilder.wrap(words, separator: separator) ?? [words.joined(separator: separator)]).joined(
                separator: "\n")
    }

    public func canSplit(_ id: UUID) -> Bool {
        cues.first { $0.id == id }.map { units(of: $0).count > 1 } ?? false
    }

    /// The cue as two at the word that halves its text best, its time shared by their lengths.
    public mutating func split(_ id: UUID) {
        guard canSplit(id), let index = cues.firstIndex(where: { $0.id == id }) else { return }
        let cue = cues[index]
        let words = units(of: cue)
        let separator = separator
        let length = { (part: ArraySlice<String>) in part.joined(separator: separator).count }
        let split =
            (1..<words.count).min { lhs, rhs in
                abs(length(words[..<lhs]) - length(words[lhs...])) < abs(length(words[..<rhs]) - length(words[rhs...]))
            } ?? 1
        let first = Array(words[..<split])
        let second = Array(words[split...])
        let share = Double(length(words[..<split])) / Double(max(length(words[..<split]) + length(words[split...]), 1))
        let middle = cue.start + (cue.end - cue.start) * share
        cues[index] = SubtitleCue(
            id: cue.id, start: cue.start, end: middle,
            text: (CueBuilder.wrap(first, separator: separator) ?? first).joined(separator: "\n"))
        cues.insert(
            SubtitleCue(
                start: middle, end: cue.end,
                text: (CueBuilder.wrap(second, separator: separator) ?? second).joined(separator: "\n")),
            at: index + 1)
    }

    /// The cue showing at `time`, if any.
    public func cue(at time: TimeInterval) -> SubtitleCue? {
        cues.first { $0.start <= time && time < $0.end }
    }

    private var separator: String { WordSpacing.separator(for: language) }

    /// The cue's words; each character in a language written without spaces.
    private func units(of cue: SubtitleCue) -> [String] {
        let parts = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        return separator.isEmpty ? parts.joined().map(String.init) : parts
    }
}
