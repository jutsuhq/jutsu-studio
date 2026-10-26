import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import JutsuCore

/// Fallback when the export preset can't fit the size limit: decode and re-encode H.264/AAC at a
/// bitrate computed from the clip length.
enum VideoReencoder {
    static let audioBitRate = 128_000
    static let minimumVideoBitRate = 100_000

    /// 10% of the budget is left for container overhead and encoder overshoot.
    static func videoBitRate(duration: TimeInterval, byteLimit: Int64, hasAudio: Bool) -> Int {
        let bitsPerSecond = Double(byteLimit) * 8 * 0.9 / max(duration, 1)
        let video = bitsPerSecond - (hasAudio ? Double(audioBitRate) : 0)
        return max(Int(video), minimumVideoBitRate)
    }

    static func reencode(
        _ request: VideoRequest, to output: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let pipeline = try await makePipeline(request, output: output)
        let reader = pipeline.reader
        let writer = pipeline.writer
        guard reader.startReading(), writer.startWriting() else {
            throw MediaError.exportFailed((writer.error ?? reader.error)?.localizedDescription ?? "Can't start")
        }
        writer.startSession(atSourceTime: request.timeRange.start)
        do {
            try await pump(pipeline, timeRange: request.timeRange, progress: progress)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaError.exportFailed(writer.error?.localizedDescription ?? "Writing did not complete")
        }
        progress(1)
    }

    private struct StreamPair {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
    }

    private struct Pipeline {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let streams: [StreamPair]
    }

    private static func makePipeline(_ request: VideoRequest, output: URL) async throws -> Pipeline {
        let asset = AVURLAsset(url: request.sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unsupportedFormat
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let display = MediaProbe.displaySize(naturalSize: naturalSize, transform: transform)
        // H.264 wants even sides.
        let size = request.upscaledSize ?? PixelSize(width: display.width / 2 * 2, height: display.height / 2 * 2)
        let bitRate = videoBitRate(
            duration: request.timeRange.duration.seconds, byteLimit: request.byteLimit, hasAudio: audioTrack != nil)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = request.timeRange
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.videoComposition = try await VideoComposition.make(for: asset, renderSize: size)
        var streams = [StreamPair(output: videoOutput, input: videoInput(size: size, bitRate: bitRate), isVideo: true)]
        if let audioTrack {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            streams.append(StreamPair(output: audioOutput, input: audioInput(), isVideo: false))
        }
        for stream in streams {
            guard reader.canAdd(stream.output), writer.canAdd(stream.input) else {
                throw MediaError.exportFailed("Can't set up the re-encode")
            }
            reader.add(stream.output)
            writer.add(stream.input)
        }
        return Pipeline(reader: reader, writer: writer, streams: streams)
    }

    /// Feeds both streams in turn: the writer interleaves, so draining one stream first can stall it.
    private static func pump(
        _ pipeline: Pipeline, timeRange: CMTimeRange, progress: @Sendable (Double) -> Void
    ) async throws {
        let start = timeRange.start.seconds
        let duration = max(timeRange.duration.seconds, 0.001)
        var pending = pipeline.streams
        while !pending.isEmpty {
            try Task.checkCancellation()
            var appended = false
            for (index, stream) in pending.enumerated().reversed() where stream.input.isReadyForMoreMediaData {
                guard let sample = stream.output.copyNextSampleBuffer() else {
                    guard pipeline.reader.status != .failed else {
                        throw MediaError.exportFailed(pipeline.reader.error?.localizedDescription ?? "Reading failed")
                    }
                    stream.input.markAsFinished()
                    pending.remove(at: index)
                    continue
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard stream.input.append(sample) else {
                    throw MediaError.exportFailed(pipeline.writer.error?.localizedDescription ?? "Writing failed")
                }
                appended = true
                if stream.isVideo {
                    progress(min(max((time - start) / duration, 0), 1))
                }
            }
            if !appended {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private static func videoInput(size: PixelSize, bitRate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
        )
        input.expectsMediaDataInRealTime = false
        return input
    }

    static func audioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitRate,
            ]
        )
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// Decoded audio in the shape the AAC input above expects.
    static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
