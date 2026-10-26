import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import JutsuCore
import VideoToolbox

/// Where the on-device engines' frame loops run: on a thread of their own rather than on Swift's few cooperative
/// threads. `copyNextSampleBuffer` and the writer's back-pressure block; with every cooperative thread blocked in such
/// calls the AVFoundation work they wait for stalled too, and with it every media test running at once.
enum FrameLoop {
    /// Runs `body` on `FrameLoopExecutor` where macOS has task executors (15 and later; the engines need 15.4).
    static func run<T>(_ body: () async throws -> T) async throws -> T {
        if #available(macOS 15, *) {
            return try await withTaskExecutorPreference(FrameLoopExecutor.shared) { try await body() }
        }
        return try await body()
    }
}

/// One serial queue, which has a thread of its own whatever the cooperative pool is doing. Runs take turns on it.
/// Each job runs at its task's priority, as it did on the cooperative pool, so a run started at background priority
/// stays there.
@available(macOS 15, *)
final class FrameLoopExecutor: TaskExecutor {
    static let shared = FrameLoopExecutor()
    private let queue = DispatchQueue(label: "com.jutsustudio.frame-loop")

    func enqueue(_ job: consuming ExecutorJob) {
        // TaskPriority's raw values are the QoS classes'.
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_t(UInt32(job.priority.rawValue))) ?? .default
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) { job.runSynchronously(on: executor) }
    }
}

/// A clip as the on-device engines read it: its first video track, frame by frame, in its stored orientation.
struct FrameSource {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: AVAssetTrack?
    /// As stored, before the track's rotation.
    let naturalSize: PixelSize
    let transform: CGAffineTransform
    let frameRate: Double
    /// In seconds.
    let duration: TimeInterval
    let isH264: Bool
    /// More than 8 bits a component, or an HDR transfer function.
    let isTenBit: Bool
    /// PQ or HLG.
    let isHDR: Bool
    /// The clip's color tags as its format says them (`kCMFormatDescriptionExtension_ColorPrimaries`, …), which the
    /// writer gets only where its codec takes them (`ColorTags.writable`).
    let colorTags: ColorTags

    /// H.264 stays H.264 where it can hold the frame; HDR goes to HEVC, the codec that carries its transfer.
    func codec(for output: PixelSize) -> EnhanceCodec {
        EnhanceCodec.of(output: output, sourceIsH264: isH264 && !isHDR)
    }

    /// Frames of `size` as the clip's rotation shows them.
    func displaySize(of size: PixelSize) -> PixelSize {
        MediaProbe.displaySize(naturalSize: CGSize(width: size.width, height: size.height), transform: transform)
    }

    static func load(_ url: URL) async throws -> FrameSource {
        let asset = AVURLAsset(url: url)
        let video = try await MediaProbe.unsupportedOnFailure { try await asset.loadTracks(withMediaType: .video) }
        guard let video = video.first else { throw MediaError.unsupportedFormat }
        let audio = try await MediaProbe.unsupportedOnFailure { try await asset.loadTracks(withMediaType: .audio) }
        let (size, transform, frameRate, range, formats) = try await MediaProbe.unsupportedOnFailure {
            try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange, .formatDescriptions)
        }
        guard let format = formats.first, size.width >= 1, size.height >= 1 else { throw MediaError.unsupportedFormat }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let depth = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int ?? 8
        let tags = ColorTags(extensions)
        return FrameSource(
            asset: asset, video: video, audio: audio.first,
            naturalSize: PixelSize(width: Int(size.width.rounded()), height: Int(size.height.rounded())),
            transform: transform, frameRate: Double(frameRate), duration: range.duration.seconds,
            isH264: CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
            isTenBit: depth > 8 || tags.isHDR, isHDR: tags.isHDR, colorTags: tags)
    }
}

/// A clip's color primaries, transfer function and YCbCr matrix, as its format description names them.
struct ColorTags: Equatable {
    var primaries: String?
    var transfer: String?
    var matrix: String?

    init(primaries: String? = nil, transfer: String? = nil, matrix: String? = nil) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }

    init(_ extensions: [String: Any]) {
        primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
    }

    var isHDR: Bool {
        transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ || transfer == AVVideoTransferFunction_ITU_R_2100_HLG
    }

    /// The writer's color properties for `codec`: each tag the encoder takes for it as it is, BT.709 for the rest.
    /// AVAssetWriterInput raises an exception nothing can catch on others, such as a gamma transfer function, P22
    /// primaries or a P3 matrix.
    func writable(for codec: EnhanceCodec) -> [String: String] {
        let isHEVC = codec == .hevc
        let allowedPrimaries =
            [AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_SMPTE_C]
            + (isHEVC ? [AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_ITU_R_2020] : [])
        let allowedTransfers =
            [AVVideoTransferFunction_ITU_R_709_2]
            + (isHEVC ? [AVVideoTransferFunction_SMPTE_ST_2084_PQ, AVVideoTransferFunction_ITU_R_2100_HLG] : [])
        let allowedMatrices =
            [AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_601_4]
            + (isHEVC ? [AVVideoYCbCrMatrix_ITU_R_2020] : [])
        func pick(_ tag: String?, from allowed: [String]) -> String {
            tag.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed[0]
        }
        return [
            AVVideoColorPrimariesKey: pick(primaries, from: allowedPrimaries),
            AVVideoTransferFunctionKey: pick(transfer, from: allowedTransfers),
            AVVideoYCbCrMatrixKey: pick(matrix, from: allowedMatrices),
        ]
    }
}

/// A clip read frame by frame and a new MP4 written frame by frame, for the on-device engines. Frames come and go in
/// one pixel format, IOSurface-backed as VideoToolbox's frame processors want them; the result keeps the clip's
/// rotation and colors, and its sound as it is or none.
final class FramePipeline {
    let source: FrameSource
    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var sound: Sound?
    private let output: URL

    private struct Sound {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        var isFinished = false
    }

    /// - Parameters:
    ///   - size: the written frames' size, in the clip's stored orientation.
    ///   - frameRate: the result's, for the encoder's bit rate.
    init(
        _ source: FrameSource, to output: URL, pixelFormat: OSType, size: PixelSize, frameRate: Double,
        keepsAudio: Bool
    ) async throws {
        self.source = source
        self.output = output
        reader = try AVAssetReader(asset: source.asset)
        videoOutput = AVAssetReaderTrackOutput(
            track: source.video,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        videoOutput.alwaysCopiesSampleData = false
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        videoInput = Self.videoInput(source, size: size, frameRate: frameRate)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw MediaError.exportFailed("Can't set up the video")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        if keepsAudio, let track = source.audio {
            sound = try await Self.sound(of: track, reader: reader, writer: writer)
        }
    }

    func start() throws {
        guard reader.startReading(), writer.startWriting() else {
            throw MediaError.exportFailed((writer.error ?? reader.error)?.localizedDescription ?? "Can't start")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// The clip's next frame and its time; `nil` after the last.
    func nextFrame() throws -> TimedFrame? {
        guard let sample = videoOutput.copyNextSampleBuffer() else {
            guard reader.status != .failed else {
                throw MediaError.exportFailed(reader.error?.localizedDescription ?? "Reading failed")
            }
            return nil
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return try nextFrame() }
        return TimedFrame(buffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// Waits until the writer takes the frame, passing the sound on meanwhile, which the writer interleaves.
    func append(_ frame: TimedFrame) async throws {
        while !videoInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try checkWriting()
            if try !feedSound() { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard adaptor.append(frame.buffer, withPresentationTime: frame.time) else {
            throw MediaError.exportFailed(writer.error?.localizedDescription ?? "Writing failed")
        }
    }

    /// Writes the rest of the sound, then closes the file.
    func finish() async throws {
        videoInput.markAsFinished()
        while sound.map({ !$0.isFinished }) ?? false {
            try Task.checkCancellation()
            try checkWriting()
            if try !feedSound() { try await Task.sleep(for: .milliseconds(5)) }
        }
        reader.cancelReading()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaError.exportFailed(writer.error?.localizedDescription ?? "Writing did not complete")
        }
    }

    /// Stops both sides and deletes what was written.
    func cancel() {
        reader.cancelReading()
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: output)
    }

    private func checkWriting() throws {
        guard writer.status == .writing else {
            throw MediaError.exportFailed(writer.error?.localizedDescription ?? "Writing stopped")
        }
    }

    /// Appends the sound the writer takes now; whether any went. Throws when reading the sound failed, rather than
    /// cutting it short.
    private func feedSound() throws -> Bool {
        guard var sound, !sound.isFinished else { return false }
        var fed = false
        while sound.input.isReadyForMoreMediaData {
            guard let sample = sound.output.copyNextSampleBuffer() else {
                guard reader.status != .failed else {
                    throw MediaError.exportFailed(reader.error?.localizedDescription ?? "Reading the sound failed")
                }
                sound.input.markAsFinished()
                sound.isFinished = true
                break
            }
            guard sound.input.append(sample) else { break }
            fed = true
        }
        self.sound = sound
        return fed
    }

    private static func videoInput(_ source: FrameSource, size: PixelSize, frameRate: Double) -> AVAssetWriterInput {
        let codec = source.codec(for: size)
        // About what the benchmark's results needed to look like their sources (#13).
        let bitsPerPixel = codec == .h264 ? 0.12 : 0.08
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(Double(size.width * size.height) * max(frameRate, 1) * bitsPerPixel),
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
        ]
        if codec == .hevc, source.isTenBit {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoColorPropertiesKey: source.colorTags.writable(for: codec),
                AVVideoCompressionPropertiesKey: compression,
                AVVideoEncoderSpecificationKey: [
                    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
                ],
            ])
        input.transform = source.transform
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// The clip's sound as it is; decoded and written as AAC when an MP4 can't hold it as it is (PCM from a MOV).
    private static func sound(
        of track: AVAssetTrack, reader: AVAssetReader, writer: AVAssetWriter
    ) async throws
        -> Sound
    {
        let formats = try await track.load(.formatDescriptions)
        var output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        var input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
        if !writer.canAdd(input) {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: VideoReencoder.pcmSettings)
            input = VideoReencoder.audioInput()
        }
        output.alwaysCopiesSampleData = false
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else { throw MediaError.exportFailed("Can't keep the sound") }
        reader.add(output)
        writer.add(input)
        return Sound(output: output, input: input)
    }
}

/// A frame and the time it is shown at.
struct TimedFrame {
    let buffer: CVPixelBuffer
    let time: CMTime
}

/// Frames for the engines to write into: IOSurface-backed, of one size and format. Not the writer's own pool, which
/// VideoToolbox can replace while it encodes (#116).
final class FramePool {
    private let pool: CVPixelBufferPool

    convenience init(size: PixelSize, pixelFormat: OSType) throws {
        try self.init(size: size, attributes: FrameFormat.plain(pixelFormat).destination)
    }

    /// - Parameter attributes: an engine's pixel buffer attributes (`FrameFormat`), which this sizes.
    init(size: PixelSize, attributes engine: [String: any Sendable]) throws {
        var attributes: [String: Any] = engine
        attributes[kCVPixelBufferWidthKey as String] = size.width
        attributes[kCVPixelBufferHeightKey as String] = size.height
        if attributes[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
            let pool
        else { throw MediaError.exportFailed("Can't make frames of \(size.width)×\(size.height)") }
        self.pool = pool
    }

    func make() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw MediaError.exportFailed("No frame (\(status))") }
        return buffer
    }
}

/// The frames an engine takes and gives, as VideoToolbox's configuration describes them.
struct FrameFormat {
    /// What the engine reads.
    let source: [String: any Sendable]
    /// What it writes into.
    let destination: [String: any Sendable]

    /// The pixel format the reader converts the clip's frames into: the engine's source format.
    var pixelFormat: OSType { Self.pixelFormat(in: source) }

    /// Both sides in one pixel format, IOSurface-backed: a stand-in engine's.
    static func plain(_ pixelFormat: OSType) -> FrameFormat {
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        return FrameFormat(source: attributes, destination: attributes)
    }

    /// The first format the attributes name, one or a list; 64-bit half float, which both engines took in the
    /// benchmark (#13), when they name none.
    static func pixelFormat(in attributes: [String: any Sendable]) -> OSType {
        let value = attributes[kCVPixelBufferPixelFormatTypeKey as String]
        if let number = value as? NSNumber { return number.uint32Value }
        if let numbers = value as? [NSNumber], let first = numbers.first { return first.uint32Value }
        return kCVPixelFormatType_64RGBAHalf
    }
}
