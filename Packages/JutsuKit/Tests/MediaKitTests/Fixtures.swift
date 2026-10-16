import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import MediaKit

/// Media fixtures are generated per test instead of committed as binaries.
enum Fixtures {
    struct WriteFailed: Error {
        let underlying: (any Error)?
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Silent video of frames that fade through grey, `frameRate` fps.
    /// - Parameter shade: the grey level of each frame, by its index.
    static func makeVideo(
        in directory: URL, width: Int = 720, height: Int = 480, seconds: Int, frameRate: Int = 5,
        codec: AVVideoCodecType = .h264, fileType: AVFileType = .mp4,
        shade: (Int) -> Int32 = { Int32(30 + $0 % 200) }
    ) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileType == .mov ? "mov" : "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw WriteFailed(underlying: writer.error) }
        writer.startSession(atSourceTime: .zero)

        // Frames come from a pool of the fixture's own, not `adaptor.pixelBufferPool`: VideoToolbox can replace the
        // encoder's pool while several tests encode at once, and a frame taken from the replaced pool crashed the
        // test bundle with SIGSEGV in `CVPixelBufferPoolCreatePixelBuffer` (#116).
        let pool = try makePool(width: width, height: height)
        for frame in 0..<(seconds * frameRate) {
            while !input.isReadyForMoreMediaData, writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing else { throw WriteFailed(underlying: writer.error) }
            let buffer = try makeFrame(pool: pool, shade: shade(frame))
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw WriteFailed(underlying: writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw WriteFailed(underlying: writer.error) }
        return url
    }

    private static func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
            let pool
        else { throw WriteFailed(underlying: nil) }
        return pool
    }

    private static func makeFrame(pool: CVPixelBufferPool, shade: Int32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
            let buffer
        else { throw WriteFailed(underlying: nil) }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), shade, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// `video` with a 440 Hz AAC tone as long as the video, as a new MP4.
    static func addingTone(to video: URL, in directory: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: video)
        guard let picture = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw WriteFailed(underlying: nil)
        }
        let pictureRange = try await picture.load(.timeRange)

        let tone = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let rate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(pictureRange.duration.seconds * rate)),
            let samples = buffer.floatChannelData?[0]
        else { throw WriteFailed(underlying: nil) }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.2 * sin(Float(index) * 2 * .pi * 440 / Float(rate))
        }
        // The file is finished when it goes out of scope.
        try AVAudioFile(forWriting: tone, settings: settings).write(from: buffer)

        let soundAsset = AVURLAsset(url: tone)
        guard let sound = try await soundAsset.loadTracks(withMediaType: .audio).first else {
            throw WriteFailed(underlying: nil)
        }
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(pictureRange, of: picture, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(try await sound.load(.timeRange), of: sound, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw WriteFailed(underlying: nil) }
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        try await VideoExport.run(ExportSessionBox(session), progress: { _ in })
        return output
    }

    /// Solid-colour image; nil when this machine has no encoder for `type` (HEIC on some VMs).
    /// - Parameter orientation: the EXIF orientation to store, 1 (upright) by default.
    static func makeImage(in directory: URL, width: Int, height: Int, type: UTType, orientation: Int = 1) -> URL? {
        let url = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "img")
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return nil }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    static func imageSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
