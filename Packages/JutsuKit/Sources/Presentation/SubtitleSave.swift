import JutsuCore

/// What the editor's Done does, given what its version holds now: the editor saves onto the version it opened on, and
/// never silently over subtitles a run saved there since.
public enum SubtitleSave: Sendable, Equatable {
    case save
    /// The version's subtitles aren't the ones the editor opened with: a run made them again, or they were removed.
    case changedMeanwhile
    /// The version is no longer in the library.
    case versionGone

    /// - Parameter stored: the version's subtitles now; `nil` when the version is gone, `.some(nil)` when it has none.
    public static func decide(opened: Subtitles, stored: Subtitles??) -> SubtitleSave {
        guard let stored else { return .versionGone }
        return stored == opened ? .save : .changedMeanwhile
    }
}
