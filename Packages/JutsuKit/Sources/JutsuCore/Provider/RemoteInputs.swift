import Foundation

/// Uploaded inputs of one job, in the order of `JobSpec.references`.
public struct RemoteInputs: Codable, Sendable, Hashable {
    /// `nil` for a clip made without a source video.
    public var video: RemoteAsset?
    public var images: [RemoteAsset]
    /// The uploaded speech (`JobSpec.speech`); `nil` without one, and in jobs stored before it existed.
    public var audio: RemoteAsset?

    public init(video: RemoteAsset?, images: [RemoteAsset], audio: RemoteAsset? = nil) {
        self.video = video
        self.images = images
        self.audio = audio
    }
}
