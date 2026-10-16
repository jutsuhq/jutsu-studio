import AVFoundation
import CoreMedia
import Foundation
import JutsuCore

/// A silent H.264 cut of a result for sharing; the caller picks the range and size (`ShortPreview`).
public enum PreviewExport {
    public static func export(
        _ source: URL, range: ClosedRange<TimeInterval>, renderSize: PixelSize, byteLimit: Int64, to output: URL
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unsupportedFormat
        }
        let transform = try await track.load(.preferredTransform)
        // Only the video track goes in, so the file has no audio and messengers loop it like a GIF.
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.exportFailed("Can't add a video track") }
        let timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        try videoTrack.insertTimeRange(timeRange, of: track, at: .zero)
        videoTrack.preferredTransform = transform

        // Medium quality encodes H.264 at about 1 Mbit/s for a 480p frame, so 5 s land near 0.6 MB;
        // the video composition sets the 480p size, and `fileLengthLimit` is a hard cap if an encode overshoots.
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetMediumQuality)
        else { throw MediaError.exportFailed("No export session for this file") }
        session.outputURL = output
        session.outputFileType = .mp4
        session.fileLengthLimit = byteLimit
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = try await VideoComposition.make(for: composition, renderSize: renderSize)
        try await VideoExport.run(ExportSessionBox(session), progress: { _ in })
    }
}
