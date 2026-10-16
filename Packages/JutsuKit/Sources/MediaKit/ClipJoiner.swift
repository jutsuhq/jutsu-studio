import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import JutsuCore

/// "Join with original": a source clip and the part Seedance's Extend added after it, as one file. The API returns
/// only the new part, so the two are put together here.
public enum ClipJoiner {
    /// Writes `range` of `original` followed by `addition` to `output` as H.264 MP4, at the original's frame size; the
    /// extension is scaled to fill it. The extension's first frame is the original's last (seen live, issue #134), so
    /// it is left out, and the extension's sound with it, to keep that sound in step with its picture. A part without
    /// sound is silent in the joined file. A failed or canceled join leaves nothing at `output`, and an existing file
    /// there is never replaced.
    public static func join(
        _ original: URL, range: ClosedRange<TimeInterval>, then addition: URL, to output: URL
    ) async throws {
        let composition = AVMutableComposition()
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var renderSize: PixelSize?
        var frameRate: Float = 0
        var cursor = CMTime.zero
        for (url, part) in [(original, Optional(range)), (addition, nil)] {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaError.unsupportedFormat
            }
            let (whole, naturalSize, transform, rate) = try await video.load(
                .timeRange, .naturalSize, .preferredTransform, .nominalFrameRate)
            let timeRange =
                if let part {
                    Self.timeRange(part).intersection(whole)
                } else {
                    try await Self.droppingFirstFrame(of: video, in: whole)
                }
            guard timeRange.duration > .zero else { throw MediaError.invalidRange }
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw MediaError.exportFailed("Can't add a video track") }
            try track.insertTimeRange(timeRange, of: video, at: cursor)
            if let sound = try await asset.loadTracks(withMediaType: .audio).first, let audio {
                let soundRange = try await sound.load(.timeRange).intersection(timeRange)
                if soundRange.duration > .zero {
                    try audio.insertTimeRange(soundRange, of: sound, at: cursor + (soundRange.start - timeRange.start))
                }
            }
            let size =
                renderSize
                ?? Self.evenSize(VideoComposition.displaySize(naturalSize: naturalSize, transform: transform))
            renderSize = size
            frameRate = max(frameRate, rate)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(
                try VideoComposition.placement(naturalSize: naturalSize, transform: transform, renderSize: size),
                at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: timeRange.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + timeRange.duration
        }
        guard let renderSize else { throw MediaError.unsupportedFormat }
        if let audio, audio.segments.isEmpty { composition.removeTrack(audio) }
        try await export(
            composition, instructions: instructions, renderSize: renderSize, frameRate: frameRate, to: output)
    }

    /// Renders the parts at `renderSize` into a hidden file next to `output`, then moves it there.
    private static func export(
        _ composition: AVMutableComposition, instructions: [AVMutableVideoCompositionInstruction],
        renderSize: PixelSize, frameRate: Float, to output: URL
    ) async throws {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: renderSize.width, height: renderSize.height)
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: frameRate > 0 ? CMTimeScale(frameRate.rounded()) : 30)
        videoComposition.instructions = instructions

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw MediaError.exportFailed("No export session for these clips") }
        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial.mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        session.outputURL = partial
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        try await VideoExport.run(ExportSessionBox(session), progress: { _ in })
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// `range` without its first frame, which an extension shares with the clip it continues. Its own frame length,
    /// so an extension of another frame rate than the original loses exactly one frame. A part of a single frame stays
    /// whole.
    static func droppingFirstFrame(of track: AVAssetTrack, in range: CMTimeRange) async throws -> CMTimeRange {
        let frame = try await firstFrameDuration(of: track, in: range)
        guard frame > .zero, frame < range.duration else { return range }
        return CMTimeRange(start: range.start + frame, end: range.end)
    }

    /// From the first frame's presentation time to the second's; the track's shortest frame, else its nominal rate's
    /// frame, when the samples can't be stepped through.
    private static func firstFrameDuration(of track: AVAssetTrack, in range: CMTimeRange) async throws -> CMTime {
        let (canStep, shortest, rate) = try await track.load(
            .canProvideSampleCursors, .minFrameDuration, .nominalFrameRate)
        if canStep, let cursor = track.makeSampleCursor(presentationTimeStamp: range.start) {
            let first = cursor.presentationTimeStamp
            if cursor.stepInPresentationOrder(byCount: 1) == 1 {
                let frame = cursor.presentationTimeStamp - first
                if frame.isNumeric, frame > .zero { return frame }
            }
        }
        if shortest.isNumeric, shortest > .zero { return shortest }
        return rate > 0 ? CMTime(seconds: 1 / Double(rate), preferredTimescale: 600) : .zero
    }

    private static func timeRange(_ range: ClosedRange<TimeInterval>) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
    }

    /// H.264 needs even sides.
    private static func evenSize(_ size: CGSize) -> PixelSize {
        let even = { (side: CGFloat) in max(2, Int((abs(side) / 2).rounded()) * 2) }
        return PixelSize(width: even(size.width), height: even(size.height))
    }
}
