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

    public static let parakeetNotDownloaded = String(
        localized: "Parakeet Ultra isn't downloaded yet. Download it in Settings › Subtitles.", bundle: .module)
    public static let parakeetName = "Parakeet Ultra"
    /// Under the model's name in Settings.
    public static let parakeetSummary = String(
        localized:
            "NVIDIA's Parakeet TDT 0.6B v3, post-trained by moondream, in a Core ML build by FluidInference. Hears 25 European languages on this Mac, often better than the built-in models.",
        bundle: .module)
    public static let parakeetCredit = String(
        localized:
            "Parakeet Ultra speech model: NVIDIA Parakeet TDT 0.6B v3, post-trained by moondream, Core ML build by FluidInference, CC BY 4.0. Run with FluidAudio, Apache License 2.0.",
        bundle: .module)
    public static let modelsFolder = String(localized: "Speech models", bundle: .module)
    public static let downloadFailedTitle = String(localized: "Can't download Parakeet Ultra", bundle: .module)
    public static let removeFailedTitle = String(localized: "Can't remove Parakeet Ultra", bundle: .module)

    /// "632 MB download · about 1.5 GB of memory while it runs · 25 languages · CC BY 4.0".
    public static var parakeetFacts: String {
        let download = ByteCountFormatter.string(fromByteCount: ParakeetUltra.manifest.size, countStyle: .file)
        let memory = ByteCountFormatter.string(
            fromByteCount: Int64(ParakeetUltra.memoryMB) << 20, countStyle: .memory)
        return [
            String(localized: "\(download) download", bundle: .module),
            String(localized: "about \(memory) of memory while it runs", bundle: .module),
            String(localized: "\(ParakeetUltra.languages.count) languages", bundle: .module),
            ParakeetUltra.license,
        ].joined(separator: " · ")
    }

    /// The languages Parakeet hears, by name, in the app's language.
    public static var parakeetLanguages: String {
        ParakeetUltra.languages.map(languageName).sorted().formatted(.list(type: .and))
    }

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
        case .modelNotDownloaded?: parakeetNotDownloaded
        case .notEnoughMemory(let needed, let free)?:
            String(
                localized:
                    "Parakeet Ultra needs about \(needed) MB of free memory, and \(free) MB are free now. Quit other apps and try again.",
                bundle: .module)
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

extension SubtitleEngine {
    public var title: String {
        switch self {
        case .builtIn: String(localized: "Built-in", bundle: .module)
        case .parakeet: SubtitleText.parakeetName
        }
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
