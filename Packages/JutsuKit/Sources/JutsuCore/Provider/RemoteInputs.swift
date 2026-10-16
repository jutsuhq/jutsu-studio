import Foundation

/// Uploaded inputs of one job, in the order of `JobSpec.references`.
public struct RemoteInputs: Codable, Sendable, Hashable {
    /// `nil` for a clip made without a source video.
    public var video: RemoteAsset?
    public var images: [RemoteAsset]

    public init(video: RemoteAsset?, images: [RemoteAsset]) {
        self.video = video
        self.images = images
    }
}
