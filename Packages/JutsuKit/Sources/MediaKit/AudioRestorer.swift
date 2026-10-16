import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import JutsuCore

extension MediaPreparer {
    /// A clip made without a source keeps its own sound: the model made it, or none when the job asked for silence.
    /// So does Extend's new part, which no part of the source's sound belongs to. An operation's source is a whole
    /// result, Extend's too, whose sound is the one to put back.
    public func restoreAudio(of spec: JobSpec, result: URL, to output: URL) async throws -> Bool {
        guard let clip = spec.source, spec.mode != .extend || spec.operation != nil else { return false }
        return try await clip.withAccess { source in
            try await AudioRestorer.restore(spec.audio, range: clip.range, source: source, result: result, to: output)
        }
    }
}

/// Sets a downloaded result's sound per `AudioPlan`. The video track is copied with a passthrough
/// export, never re-encoded.
enum AudioRestorer {
    static func restore(
        _ option: AudioOption, range: ClosedRange<TimeInterval>, source: URL, result: URL, to output: URL
    ) async throws -> Bool {
        // Named `.<UUID>.mp4` and `.<UUID>.m4a`: JobEngine's `ScratchFile` deletes them after a crash.
        let scratch = output.deletingLastPathComponent()
        let input = scratch.appendingPathComponent(".\(UUID().uuidString).mp4")
        try linkOrCopy(result, to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let asset = AVURLAsset(url: input)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unsupportedFormat
        }
        let resultAudio = try await asset.loadTracks(withMediaType: .audio)
        let (videoRange, transform) = try await video.load(.timeRange, .preferredTransform)
        // Tracks need their asset alive, so it is kept here rather than inside the `if`.
        let sourceAsset = AVURLAsset(url: source)
        var sourceAudio: AVAssetTrack?
        if option != .mute {
            sourceAudio = try await sourceAsset.loadTracks(withMediaType: .audio).first
        }
        let sourceAudioEnd = try await sourceAudio?.load(.timeRange).end.seconds

        let plan = AudioPlan.make(
            option: option, sourceRange: range, sourceAudioEnd: sourceAudioEnd,
            resultDuration: videoRange.duration.seconds, resultHasAudio: !resultAudio.isEmpty)
        try? FileManager.default.removeItem(at: output)
        do {
            switch plan {
            case .keep:
                return false
            case .removeAudio:
                try await mux(video, range: videoRange, transform: transform, audioFile: nil, to: output)
            case .addSource(let audioRange, let fadeOut):
                guard let sourceAudio else { return false }
                let audioFile = scratch.appendingPathComponent(".\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: audioFile) }
                try await renderAudio(sourceAudio, range: audioRange, fadeOut: fadeOut, to: audioFile)
                try await mux(video, range: videoRange, transform: transform, audioFile: audioFile, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return true
    }

    /// AVFoundation picks the container by file extension, and the partial download has none.
    private static func linkOrCopy(_ file: URL, to destination: URL) throws {
        do {
            try FileManager.default.linkItem(at: file, to: destination)
        } catch {
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }

    /// Cuts the source audio to AAC. It is re-encoded because a passthrough export ignores the audio
    /// mix that fades it, and because the source codec (e.g. PCM from a .mov) may not fit in MP4.
    private static func renderAudio(
        _ track: AVAssetTrack, range: ClosedRange<TimeInterval>, fadeOut: ClosedRange<TimeInterval>?, to output: URL
    ) async throws {
        let composition = AVMutableComposition()
        guard
            let audio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.exportFailed("Can't add an audio track") }
        try audio.insertTimeRange(timeRange(range), of: track, at: .zero)
        var mix: AVMutableAudioMix?
        if let fadeOut {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: timeRange(fadeOut))
            let fade = AVMutableAudioMix()
            fade.inputParameters = [parameters]
            mix = fade
        }
        try await export(composition, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, audioMix: mix, to: output)
    }

    /// The result's video with `audioFile`'s audio, cut to the video's length, or with no audio.
    private static func mux(
        _ video: AVAssetTrack, range videoRange: CMTimeRange, transform: CGAffineTransform, audioFile: URL?,
        to output: URL
    ) async throws {
        let audioAsset = audioFile.map { AVURLAsset(url: $0) }
        var audio: (track: AVAssetTrack, range: CMTimeRange)?
        if let audioAsset {
            guard let track = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                throw MediaError.exportFailed("The rendered audio has no track")
            }
            let trackRange = try await track.load(.timeRange)
            audio = (track, trackRange)
        }

        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.exportFailed("Can't add a video track") }
        try videoTrack.insertTimeRange(videoRange, of: video, at: .zero)
        videoTrack.preferredTransform = transform
        if let audio {
            guard
                let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw MediaError.exportFailed("Can't add an audio track") }
            let length = CMTimeMinimum(audio.range.duration, videoRange.duration)
            try audioTrack.insertTimeRange(
                CMTimeRange(start: audio.range.start, duration: length), of: audio.track, at: .zero)
        }
        try await export(composition, preset: AVAssetExportPresetPassthrough, fileType: .mp4, to: output)
    }

    private static func export(
        _ asset: AVAsset, preset: String, fileType: AVFileType, audioMix: AVAudioMix? = nil, to output: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.exportFailed("No \(preset) export for this file")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.audioMix = audioMix
        try await VideoExport.run(ExportSessionBox(session), progress: { _ in })
    }

    private static func timeRange(_ seconds: ClosedRange<TimeInterval>) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: seconds.lowerBound, preferredTimescale: 48_000),
            end: CMTime(seconds: seconds.upperBound, preferredTimescale: 48_000))
    }
}
