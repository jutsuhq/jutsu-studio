import Foundation
import JutsuCore

extension Job {
    /// The inputs of an Edit or Extend (`mode`) of this result, for Create to open with the result as the source
    /// on Seedance 2.5, at the result's resolution. The prompt is left for the user: Edit and Extend need their own.
    /// Edit selects up to the first 30 s, Extend up to the last 30 s, ending at the end of the clip. `nil` for
    /// another mode, or without a downloaded result.
    public func followUp(_ mode: Mode) -> JobSpec? {
        guard mode.isVideoOperation, let file = outputFile, file.isFileURL else { return nil }
        // Create probes the file again and `CreateForm.load` fits the range to it.
        let duration = max(0, outputDuration)
        let window = Validation.durationRange.upperBound
        let range = mode == .extend ? max(0, duration - window)...duration : 0...min(duration, window)
        let source = SourceClip(
            fileURL: file, duration: duration, pixelSize: outputPixelSize ?? PixelSize(width: 0, height: 0),
            range: range)
        return JobSpec(
            mode: mode, model: mode.defaultModel, source: source, resolution: spec.resolution,
            length: mode == .extend ? CreateForm.defaultLength : nil)
    }
}

extension Job {
    /// How long Higgsfield keeps a native draft finalizable: "a 480p draft that can be finalized within seven days"
    /// (`models_explore get` of `seedance_2_5`).
    public static let finalizeWindow: TimeInterval = 7 * 24 * 60 * 60

    /// When this native Seedance draft of the account (`RemoteJob.isNativeDraft`) stops being finalizable: seven days
    /// after Higgsfield completed it (`chargedAt`, else when the job finished here). `nil` for any other job.
    public var finalizeDeadline: Date? {
        guard spec.isDraft, providerKind == .account, state == .done, remote?.isNativeDraft == true,
            let completed = chargedAt ?? finishedAt
        else { return nil }
        return completed.addingTimeInterval(Self.finalizeWindow)
    }

    /// Finalize in 1080p: the draft's final, made by Higgsfield from the draft itself (`JobSpec.draftJobID`) rather
    /// than from its inputs again, for a third of a fresh 1080p render. It keeps the draft's inputs for the library
    /// and uploads nothing. `nil` unless this is a native draft that the signed-in account (`owner`) made and its
    /// seven days (`finalizeDeadline`) haven't passed at `now`.
    public func finalizeSpec(owner: String?, now: Date = Date()) -> JobSpec? {
        guard let deadline = finalizeDeadline, now < deadline, let owner, self.owner == owner,
            let draftJobID = remote?.requestID
        else { return nil }
        var final = spec
        final.resolution = .p1080
        final.isDraft = false
        final.variants = 1
        final.usesUnlimited = false
        final.draftJobID = draftJobID
        return final
    }
}

/// The texts of a native draft's finalize.
public enum FinalizeText {
    /// The button and menu item.
    public static let title = String(localized: "Finalize in 1080p", bundle: .module)
    public static let help = String(
        localized: "Higgsfield renders this draft at 1080p for a third of a new 1080p render", bundle: .module)

    /// "Finalize in 1080p until Oct 22, 2026 at 14:05", or "The 1080p finalize ended Oct 22, 2026 at 14:05" once
    /// `deadline` is past at `now`.
    public static func window(deadline: Date, now: Date = Date()) -> String {
        let date = deadline.formatted(date: .abbreviated, time: .shortened)
        return deadline > now
            ? String(localized: "Finalize in 1080p until \(date)", bundle: .module)
            : String(localized: "The 1080p finalize ended \(date)", bundle: .module)
    }
}
