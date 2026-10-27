import Foundation
import JutsuCore

/// The texts of subtitles made on-device (`SubtitleRuns`).
public enum SubtitleText {
    public static let title = String(localized: "Subtitles", bundle: .module)
    public static let versionNote = String(
        localized: "The subtitles belong to this version of the item. A later version starts without them.",
        bundle: .module)
    public static let soundNote = String(
        localized: "Only the sound is read; nothing leaves this Mac.", bundle: .module)
    public static let making = String(localized: "Making subtitles", bundle: .module)
    public static let failureTitle = String(localized: "Can't make the subtitles", bundle: .module)
    public static let noSpeech = String(localized: "No speech found", bundle: .module)
    public static let cantOpenFile = String(
        localized: "Can't open the video's file. It was moved or deleted, or the app may no longer read it.",
        bundle: .module)
    public static let unsupportedLanguage = String(
        localized: "No speech model on this Mac takes this language.", bundle: .module)
    public static let modelNeeded = String(
        localized: "The speech model for this language isn't on this Mac yet. Agree to its download in Subtitles….",
        bundle: .module)
    /// Before the first run in a language whose model isn't here.
    public static let modelNotice = String(
        localized:
            "Hearing this language needs a speech model macOS downloads from Apple once, about 200 MB. It stays for later runs.",
        bundle: .module)
    public static let modelConsent = String(localized: "Download the speech model", bundle: .module)

    /// "English (United States)" for "en-US", in the app's language.
    public static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// "Making subtitles · 42%", or that it waits.
    public static func progress(of run: SubtitleRuns.Run) -> String {
        switch run.state {
        case .waiting: "\(making) · \(OnDeviceText.waiting)"
        case .downloadingModel(let fraction):
            "\(OnDeviceText.downloadingModel) · \(CostText.percent(fraction: fraction))"
        case .working(let fraction): "\(making) · \(CostText.percent(fraction: fraction))"
        }
    }

    /// What a failed run tells the person.
    public static func message(for error: any Error) -> String {
        switch error as? TranscriptionError {
        case .cantOpenFile?: cantOpenFile
        case .noSpeech?: noSpeech
        case .unsupportedLanguage?: unsupportedLanguage
        case .modelNeeded?: modelNeeded
        case nil: error.localizedDescription
        }
    }

    public static let changedMeanwhileTitle = String(
        localized: "These subtitles were made again while you edited them", bundle: .module)
    public static let changedMeanwhileMessage = String(
        localized: "Replace the new subtitles with your edits, or keep the new ones and leave your edits.",
        bundle: .module)
    public static let versionGoneMessage = String(
        localized: "The version these subtitles belong to is no longer in the library.", bundle: .module)
    public static let notSavedTitle = String(localized: "Can't save the subtitles", bundle: .module)

    /// "0:01.2 – 0:03.4".
    public static func timeRange(of cue: SubtitleCue) -> String {
        "\(time(cue.start)) – \(time(cue.end))"
    }

    /// "1:02.3", or "1:01:02.3" past an hour.
    static func time(_ seconds: TimeInterval) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded())
        let (minutes, secs, tenth) = (tenths / 600, tenths / 10 % 60, tenths % 10)
        let rest = String(format: "%02d.%d", secs, tenth)
        return minutes >= 60 ? "\(minutes / 60):\(String(format: "%02d", minutes % 60)):\(rest)" : "\(minutes):\(rest)"
    }

    /// "English (United States) · 24 cues".
    public static func summary(of subtitles: Subtitles) -> String {
        let count = subtitles.cues.count
        return "\(languageName(subtitles.language)) · \(String(localized: "\(count) cues", bundle: .module))"
    }
}

extension OnDeviceModelConsent {
    /// Whether macOS may download the speech model of `language` (BCP 47) when it isn't on this Mac yet. The person
    /// agrees per language, as macOS downloads a model per locale.
    public func allowsSpeechModel(for language: String) -> Bool {
        defaults.bool(forKey: Self.speechKey(language))
    }

    public func agreeToSpeechModel(for language: String) {
        defaults.set(true, forKey: Self.speechKey(language))
    }

    static func speechKey(_ language: String) -> String {
        "onDevice.modelConsent.speech.\(language)"
    }
}
