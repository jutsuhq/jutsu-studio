import Foundation

/// What a result sounds like. A clip made without a source has no source audio: `mute` asks the model for no
/// sound, the others for the sound it makes.
public enum AudioOption: String, Codable, Sendable, CaseIterable {
    /// The source range's audio.
    case original
    /// No sound, even when the API kept some.
    case mute
    /// The source range's audio, faded out at the end.
    case fadeOut
    /// The model makes the soundtrack even though there is a source (Seedance only); the source's audio isn't used.
    case generated
}
