import Foundation

/// Which speech model hears a language, which languages the Subtitles sheet offers, and where a transcript is cached.
public enum SpeechSelection {
    /// Built-in: SpeechTranscriber for the locales it has, otherwise Dictation; `nil` when neither takes it.
    public static func builtIn(for language: String, in availability: SpeechAvailability) -> SpeechModel? {
        [.transcriber, .dictation].first { availability.supports($0, language) }
    }

    /// Auto: SpeechTranscriber for the locales it has, then Parakeet for its languages once it is downloaded, then
    /// Dictation; Parakeet before it is downloaded last, so a language only it takes asks for the download.
    public static func auto(for language: String, in availability: SpeechAvailability) -> SpeechModel? {
        if availability.supports(.transcriber, language) { return .transcriber }
        let parakeet = availability.supports(.parakeetUltra, language)
        if parakeet, availability.isInstalled(.parakeetUltra, language) { return .parakeetUltra }
        if availability.supports(.dictation, language) { return .dictation }
        return parakeet ? .parakeetUltra : nil
    }

    /// The model `engine` hears `language` with; `nil` when it doesn't take the language. Parakeet is named whether
    /// or not it is downloaded yet.
    public static func model(
        _ engine: SubtitleEngine, for language: String, in availability: SpeechAvailability
    ) -> SpeechModel? {
        switch engine {
        case .auto: auto(for: language, in: availability)
        case .builtIn: builtIn(for: language, in: availability)
        case .parakeet: availability.supports(.parakeetUltra, language) ? .parakeetUltra : nil
        }
    }

    /// Every model's languages, once each, in identifier order: the built-in models' locales, and Parakeet's
    /// languages that no built-in locale has, by their code.
    public static func languages(in availability: SpeechAvailability) -> [String] {
        let locales = Set(SpeechModel.allCases.filter(\.isBuiltIn).flatMap { availability.languages[$0] ?? [] })
        let covered = Set(locales.map(languageCode))
        let others = (availability.languages[.parakeetUltra] ?? []).filter { !covered.contains($0) }
        return (locales.union(others)).sorted()
    }

    /// The language the sheet starts on: the last one used when it is offered, else the system's first preferred
    /// language that is, matched exactly and then by its language alone ("en-GB" takes "en-US"), else the first.
    /// - Parameter system: the system's preferred languages, as `Locale.preferredLanguages` lists them.
    public static func preferred(_ languages: [String], last: String?, system: [String]) -> String? {
        if let last, languages.contains(last) { return last }
        for preferred in system {
            if let exact = languages.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
                return exact
            }
            if let same = languages.first(where: { languageCode($0) == languageCode(preferred) }) { return same }
        }
        return languages.first
    }

    /// "en" of "en-US", "zh" of "zh-Hans-CN".
    public static func languageCode(_ identifier: String) -> String {
        let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? identifier
        return code.lowercased()
    }

    /// The name a transcript is cached under: the same file content heard in the same language by the same model
    /// revision gives the same words. Only file-name-safe characters.
    public static func cacheKey(contentHash: String, language: String, model: SpeechModel, revision: String) -> String {
        [contentHash, language, model.rawValue, revision].map(safe).joined(separator: "_")
    }

    private static func safe(_ part: String) -> String {
        String(part.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
    }
}
