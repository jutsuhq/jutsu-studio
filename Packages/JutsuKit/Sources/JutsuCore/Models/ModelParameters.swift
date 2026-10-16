import Foundation

/// Seedance 2.5's `bitrate_mode`: how much detail the encoded result keeps. The REST schemas default to `high`, the
/// account's `generate_video` to `standard`, and the public price doesn't depend on it.
public enum SeedanceBitrate: String, Codable, Sendable, CaseIterable {
    case standard
    case high
}

/// Kling 3.0 Motion Control's `character_orientation`: whether the character faces the way it does in the reference
/// image or follows the source video (the server's default).
public enum CharacterOrientation: String, Codable, Sendable, CaseIterable {
    case image
    case video
}

/// Model parameters a connection may or may not be able to send; `Capabilities.parameters` lists the ones it can.
public enum ModelParameter: String, Sendable, CaseIterable {
    /// Seedance's `bitrate_mode`.
    case seedanceBitrate
    /// Seedance's start and end frames (`image-to-video`).
    case seedanceFrames
    /// Kling keeps the source video's sound on the server (`keep_original_sound`). REST only: the account's model
    /// has no such parameter.
    case klingOriginalSound
    /// Kling's `character_orientation`. REST only, like `klingOriginalSound`.
    case klingOrientation
    /// Cinema Studio 4.0's creative controls (`CinemaControls`). REST only: the account's model takes them as IDs
    /// its catalog doesn't list.
    case cinemaControls
    /// Kling keeps the source video's background (`JobSpec.keepsVideoBackground`, the account's
    /// `background_source`). Account only: the REST API has no background parameter.
    case klingVideoBackground
}
