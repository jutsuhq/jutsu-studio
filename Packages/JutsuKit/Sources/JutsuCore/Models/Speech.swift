import Foundation

/// A speech model that runs on-device and turns the speech of a file's sound into timed words.
public enum SpeechModel: String, Codable, Sendable, CaseIterable {
    /// macOS 26's SpeechTranscriber, the built-in model for the locales it has.
    case transcriber = "speech_transcriber"
    /// macOS 26's DictationTranscriber, the built-in model for the locales SpeechTranscriber lacks.
    case dictation
}

/// A word as it was spoken, in seconds from the start of the file.
public struct TimedWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What a speech model heard in a file.
public struct Transcript: Codable, Sendable, Hashable {
    /// BCP 47, "en-US".
    public var language: String
    public var model: SpeechModel
    /// The model's revision: another revision hears other words, so it is part of the cache key.
    public var revision: String
    public var words: [TimedWord]

    public init(language: String, model: SpeechModel, revision: String, words: [TimedWord]) {
        self.language = language
        self.model = model
        self.revision = revision
        self.words = words
    }

    public var text: String { words.map(\.text).joined(separator: WordSpacing.separator(for: language)) }
}

/// How a language writes its words apart: most with spaces; Chinese, Japanese, Cantonese, Thai, Lao, Khmer and
/// Burmese without.
public enum WordSpacing {
    static let unspaced: Set<String> = ["ja", "zh", "yue", "th", "lo", "km", "my"]

    /// What goes between two words of `language`: "" for a language written without spaces, else " ".
    public static func separator(for language: String) -> String {
        unspaced.contains(SpeechSelection.languageCode(language)) ? "" : " "
    }

    /// A model's timed runs of one result, as it writes them, as words. In a language written with spaces, a run that
    /// doesn't start with one, as a comma or the rest of a word, joins the word before it. In one written without,
    /// each run is a word of its own, and only punctuation joins the word before it.
    public static func append(_ runs: [TimedWord], to words: inout [TimedWord], language: String) {
        let spaced = !separator(for: language).isEmpty
        var startsResult = true
        for run in runs {
            let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let continues =
                spaced ? run.text.first?.isWhitespace == false : trimmed.allSatisfy { $0.isPunctuation }
            if !startsResult, continues, var last = words.popLast() {
                last.text += trimmed
                last.end = max(last.end, run.end)
                words.append(last)
            } else {
                words.append(TimedWord(text: trimmed, start: run.start, end: max(run.end, run.start)))
            }
            startsResult = false
        }
    }
}

/// The subtitles of one version of a video, made from its own file. A later version starts without any.
public struct Subtitles: Codable, Sendable, Hashable {
    /// What the model heard, as it heard it.
    public var transcript: Transcript
    /// The cues as built from the transcript (`CueBuilder`) and then edited.
    public var cues: [SubtitleCue]
    public var createdAt: Date

    public init(transcript: Transcript, cues: [SubtitleCue]? = nil, createdAt: Date = Date()) {
        self.transcript = transcript
        self.cues =
            cues ?? CueBuilder.cues(from: transcript.words, separator: WordSpacing.separator(for: transcript.language))
        self.createdAt = createdAt
    }

    public var language: String { transcript.language }
}

/// The speech models this Mac has, and the languages each takes.
public struct SpeechAvailability: Sendable, Hashable {
    /// BCP 47 identifiers by model; a model this Mac lacks has none.
    public var languages: [SpeechModel: [String]]
    /// The languages whose model is on this Mac already, so a run needs no download.
    public var installed: [SpeechModel: Set<String>]

    public init(languages: [SpeechModel: [String]] = [:], installed: [SpeechModel: Set<String>] = [:]) {
        self.languages = languages
        self.installed = installed
    }

    public static let none = SpeechAvailability()

    public func supports(_ model: SpeechModel, _ language: String) -> Bool {
        languages[model]?.contains(language) == true
    }

    public func isInstalled(_ model: SpeechModel, _ language: String) -> Bool {
        installed[model]?.contains(language) == true
    }
}

public enum TranscriptionError: Error, Sendable, Equatable {
    /// The file is missing, or the app may no longer read it.
    case cantOpenFile
    /// The file has no sound, only silence, or nothing the model took for speech.
    case noSpeech
    /// No model on this Mac takes the language.
    case unsupportedLanguage
    /// The language's model isn't here, and the person hasn't agreed to downloading it.
    case modelNeeded
}
