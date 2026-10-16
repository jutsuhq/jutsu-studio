import AVFoundation
import CoreMedia
import Foundation
import JutsuCore

/// Re-encodes a downloaded result for an editing timeline, as an `ExportPreset` says.
public enum EditingExporter {
    /// Writes `result` to `output`, which must not exist yet; an existing file is never replaced. The
    /// constant frame rate is the source clip's when its file can be read, otherwise the result's own.
    /// A canceled or failed export leaves nothing at `output`.
    /// - Parameter crop: the frame of a delivery output that crops, as `CropFrame.rect` places it on the upright
    ///   picture; `nil` keeps the whole frame.
    public static func export(
        _ result: URL, source: SourceClip?, preset: ExportPreset, crop: (CropAspect, CropFrame)? = nil,
        to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: result)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unsupportedFormat
        }
        let resultRate = try await Double(track.load(.nominalFrameRate))
        let sourceRate = await sourceFrameRate(source)
        let frame = FrameDuration.constant(forNominalRate: sourceRate ?? resultRate)
        // Renders every frame at a fixed duration, which is what makes the output constant frame rate.
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        // Otherwise a single-track asset keeps its own timing and overrides frameDuration.
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(value: frame.value, timescale: frame.timescale)
        if let (aspect, cropFrame) = crop {
            try await Self.crop(composition, to: aspect, frame: cropFrame, track: track, asset: asset)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: sessionPreset(for: preset)) else {
            throw MediaError.exportFailed("No \(preset.videoCodec.rawValue) export for this file")
        }
        let partial = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
            .appendingPathExtension(preset.fileExtension)
        defer { try? FileManager.default.removeItem(at: partial) }
        session.outputURL = partial
        session.outputFileType = fileType(for: preset)
        session.videoComposition = composition
        try await VideoExport.run(ExportSessionBox(session), progress: progress)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// One instruction that turns the track upright and moves the crop's corner to the origin, rendered at the
    /// crop's size. Sides are rounded down to even numbers, which the encoders need.
    private static func crop(
        _ composition: AVMutableVideoComposition, to aspect: CropAspect, frame: CropFrame, track: AVAssetTrack,
        asset: AVAsset
    ) async throws {
        let (natural, transform, duration) = try await (
            track.load(.naturalSize), track.load(.preferredTransform), asset.load(.duration)
        )
        let display = CGRect(origin: .zero, size: natural).applying(transform)
        let size = PixelSize(width: Int(display.width.rounded()), height: Int(display.height.rounded()))
        var rect = frame.rect(for: aspect, in: size)
        rect.width = max(2, rect.width - rect.width % 2)
        rect.height = max(2, rect.height - rect.height % 2)
        let upright = transform.concatenating(
            CGAffineTransform(translationX: -display.minX - CGFloat(rect.x), y: -display.minY - CGFloat(rect.y)))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(upright, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: rect.width, height: rect.height)
    }

    /// The ProRes preset writes LPCM audio; the H.264 one writes AAC into MP4.
    private static func sessionPreset(for preset: ExportPreset) -> String {
        switch preset.videoCodec {
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .h264: AVAssetExportPresetHighestQuality
        }
    }

    private static func fileType(for preset: ExportPreset) -> AVFileType {
        switch preset.container {
        case .quickTime: .mov
        case .mpeg4: .mp4
        }
    }

    /// `nil` when the source is gone, not readable or reports no rate.
    private static func sourceFrameRate(_ source: SourceClip?) async -> Double? {
        guard let source, source.fileURL.isFileURL else { return nil }
        let rate = try? await SecurityScopedAccess.withAccess(to: source.fileURL, bookmark: source.bookmark) { url in
            try await MediaProbe.probe(url).frameRate
        }
        return rate.flatMap { $0 > 0 ? $0 : nil }
    }
}
