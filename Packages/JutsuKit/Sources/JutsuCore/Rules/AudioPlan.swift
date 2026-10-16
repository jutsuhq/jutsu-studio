import Foundation

/// What to do with the sound of a downloaded result. Times are in seconds.
public enum AudioPlan: Sendable, Hashable {
    /// Leave the file as it is.
    case keep
    /// Write the video again without its audio track.
    case removeAudio
    /// Put `range` of the source's audio at the start of the result. `fadeOut` is in result time.
    case addSource(range: ClosedRange<TimeInterval>, fadeOut: ClosedRange<TimeInterval>?)

    public static let fadeOutDuration: TimeInterval = 1

    /// A result that already has sound keeps it, unless muted, and one whose sound the model was asked to make
    /// (`generated`) is left as it came. The source audio is cut to the result's length and never stretched, so a
    /// result longer than the range goes silent where the audio ends.
    /// - Parameter sourceAudioEnd: Where the source's audio track ends; `nil` when it has none.
    public static func make(
        option: AudioOption, sourceRange: ClosedRange<TimeInterval>, sourceAudioEnd: TimeInterval?,
        resultDuration: TimeInterval, resultHasAudio: Bool
    ) -> AudioPlan {
        if option == .mute { return resultHasAudio ? .removeAudio : .keep }
        if option == .generated { return .keep }
        guard !resultHasAudio, let sourceAudioEnd, resultDuration > 0 else { return .keep }
        let start = max(0, sourceRange.lowerBound)
        let end = min(sourceRange.upperBound, sourceAudioEnd, start + resultDuration)
        guard end > start else { return .keep }
        let length = end - start
        let fadeOut = option == .fadeOut ? max(0, length - fadeOutDuration)...length : nil
        return .addSource(range: start...end, fadeOut: fadeOut)
    }
}
