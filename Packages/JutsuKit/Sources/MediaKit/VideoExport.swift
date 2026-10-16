import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import JutsuCore

/// Trim and transcode with the stock H.264/AAC preset. Fast path; `VideoReencoder` is the fallback.
enum VideoExport {
    /// How often the progress poller reads `AVAssetExportSession.progress` during an export.
    static let progressPollInterval: Duration = .milliseconds(250)

    static func export(
        _ request: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: request.sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaError.exportFailed("No export session for this file")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = request.timeRange
        session.fileLengthLimit = request.byteLimit
        session.shouldOptimizeForNetworkUse = true
        if let size = request.upscaledSize {
            session.videoComposition = try await VideoComposition.make(for: asset, renderSize: size)
        }
        try await run(ExportSessionBox(session), progress: progress)
    }

    static func run(_ box: ExportSessionBox, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: Self.progressPollInterval)
            }
        }
        defer { poller.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }

        switch box.session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw CancellationError()
        default:
            let reason = box.session.error?.localizedDescription ?? "status \(box.session.status.rawValue)"
            throw MediaError.exportFailed(reason)
        }
    }
}

/// Lets the progress poller and the cancellation handler reach the session.
/// Safe because configuration is finished before boxing; afterwards only `progress`, `status`, `error`
/// and `cancelExport()` are used, which AVFoundation documents for polling during an export.
final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

enum VideoComposition {
    /// Draws the display-oriented frame (preferred transform applied) scaled to fill `renderSize`.
    static func make(for asset: AVAsset, renderSize: PixelSize) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unsupportedFormat
        }
        let duration = try await asset.load(.duration)
        let (naturalSize, transform, frameRate) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            try placement(naturalSize: naturalSize, transform: transform, renderSize: renderSize), at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: renderSize.width, height: renderSize.height)
        composition.frameDuration = CMTime(value: 1, timescale: frameRate > 0 ? CMTimeScale(frameRate.rounded()) : 30)
        composition.instructions = [instruction]
        return composition
    }

    /// The frame as it is shown: `naturalSize` turned by the track's preferred transform.
    static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        CGRect(origin: .zero, size: naturalSize).applying(transform).size
    }

    /// The transform that draws a track's display-oriented frame scaled to fill `renderSize`.
    static func placement(
        naturalSize: CGSize, transform: CGAffineTransform, renderSize: PixelSize
    ) throws -> CGAffineTransform {
        let display = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard display.width > 0, display.height > 0 else { throw MediaError.unsupportedFormat }
        return
            transform
            .concatenating(CGAffineTransform(translationX: -display.minX, y: -display.minY))
            .concatenating(
                CGAffineTransform(
                    scaleX: CGFloat(renderSize.width) / display.width,
                    y: CGFloat(renderSize.height) / display.height))
    }
}
