import Foundation

/// Which speech model hears a language, which languages the Subtitles sheet offers, and where a transcript is cached.
public enum SpeechSelection {
    /// Built-in: SpeechTranscriber for the locales it has, otherwise Dictation; `nil` when neither takes it.
    public static func builtIn(for language: String, in availability: SpeechAvailability) -> SpeechModel? {
        [.transcriber, .dictation].first { availability.supports($0, language) }
    }

    /// Every model's languages, once each, in identifier order.
    public static func languages(in availability: SpeechAvailability) -> [String] {
        Array(Set(availability.languages.values.joined())).sorted()
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
