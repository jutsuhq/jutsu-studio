import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import JutsuCore
import VideoToolbox

/// Makes frames between two others: VideoToolbox's frame rate conversion, or a stand-in in tests.
protocol FrameInterpolating: AnyObject {
    /// Starts the engine for frames of `size` and says the frames it takes and gives; throws when it can't take them.
    func start(size: PixelSize) throws -> FrameFormat
    /// Fills each of `targets` with the frame at its phase (0…1) from `earlier` to `later`.
    func interpolate(
        from earlier: TimedFrame, to later: TimedFrame, phases: [Float], into targets: [TimedFrame])
        async throws
    func end()
}

/// Smooth Motion: the clip with frames made between its own (`FrameTimeline`), except across a hard cut
/// (`CutDetector`), where the nearer of the two frames is repeated rather than blending two shots into a ghost.
enum SmoothMotionRenderer {
    /// On the frame loop's own thread (`FrameLoop`).
    static func render(
        _ motion: SmoothMotion, source url: URL, to output: URL, interpolator: some FrameInterpolating,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        try await FrameLoop.run {
            try await renderFrames(motion, source: url, to: output, interpolator: interpolator, progress: progress)
        }
    }

    private static func renderFrames(
        _ motion: SmoothMotion, source url: URL, to output: URL, interpolator: some FrameInterpolating,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        let source = try await FrameSource.load(url)
        let format = try interpolator.start(size: source.naturalSize)
        defer { interpolator.end() }
        let rate = motion.outputFrameRate(source: source.frameRate)
        var timeline = FrameTimeline(duration: source.duration, frameRate: rate, slowdown: motion.slowdown)
        let pipeline = try await FramePipeline(
            source, to: output, pixelFormat: format.pixelFormat, size: source.naturalSize,
            frameRate: Double(rate), keepsAudio: motion.keepsAudio)
        let pool = try FramePool(size: source.naturalSize, attributes: format.destination)
        let luma = LumaSampler()
        try pipeline.start()
        do {
            guard var earlier = try pipeline.nextFrame() else { throw MediaError.unsupportedFormat }
            var earlierLuma = luma.thumbnail(of: earlier.buffer)
            while timeline.next < timeline.frameCount {
                let later = try pipeline.nextFrame()
                let laterLuma = later.map { luma.thumbnail(of: $0.buffer) }
                let isCut = laterLuma.map { CutDetector.isCut(earlierLuma, $0) } ?? false
                let frames = timeline.frames(from: earlier.time.seconds, until: later?.time.seconds)
                var made: [Int: CVPixelBuffer] = [:]
                let between = frames.filter { $0.phase > 0 }
                if let later, !isCut, !between.isEmpty {
                    let targets = try between.map { TimedFrame(buffer: try pool.make(), time: time($0.index, rate)) }
                    try await interpolator.interpolate(
                        from: earlier, to: later, phases: between.map { Float($0.phase) }, into: targets)
                    for (frame, target) in zip(between, targets) { made[frame.index] = target.buffer }
                }
                for frame in frames {
                    try Task.checkCancellation()
                    // At a cut each frame between takes the nearer of the two.
                    let held = isCut && frame.phase >= 0.5 ? later?.buffer : nil
                    let buffer = made[frame.index] ?? held ?? earlier.buffer
                    try await pipeline.append(TimedFrame(buffer: buffer, time: time(frame.index, rate)))
                    progress(.working(Double(frame.index + 1) / Double(max(timeline.frameCount, 1))))
                }
                guard let later, let laterLuma else { break }
                earlier = later
                earlierLuma = laterLuma
            }
            try await pipeline.finish()
        } catch {
            pipeline.cancel()
            throw error
        }
        return OnDeviceOutput(
            pixelSize: source.displaySize(of: source.naturalSize),
            duration: timeline.outputTime(of: timeline.frameCount), fileExtension: "mp4")
    }

    private static func time(_ index: Int, _ rate: Int) -> CMTime {
        CMTime(value: CMTimeValue(index), timescale: CMTimeScale(rate))
    }
}

/// Grey thumbnails of frames for `CutDetector`, `CutDetector.thumbnailSide` on the long side whatever the frame's size,
/// scaled with a Lanczos filter so every source pixel counts: the threshold then means the same at every resolution.
/// The frame's values as they are, without color management, so the luma is the encoded one the threshold was
/// measured on.
final class LumaSampler {
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false,
    ])

    func thumbnail(of buffer: CVPixelBuffer) -> [UInt8] {
        let image = CIImage(cvPixelBuffer: buffer)
        guard image.extent.width >= 1, image.extent.height >= 1 else { return [] }
        let scale = Double(CutDetector.thumbnailSide) / max(image.extent.width, image.extent.height)
        let width = max(1, Int((image.extent.width * scale).rounded()))
        let height = max(1, Int((image.extent.height * scale).rounded()))
        let small = image.clampedToExtent().applyingFilter(
            "CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            small, toBitmap: &rgba, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: nil)
        return (0..<(width * height)).map { pixel in
            let red = Double(rgba[pixel * 4])
            let green = Double(rgba[pixel * 4 + 1])
            let blue = Double(rgba[pixel * 4 + 2])
            return UInt8(min(255, (0.299 * red + 0.587 * green + 0.114 * blue).rounded()))
        }
    }
}

/// VideoToolbox's frame rate conversion at its quality setting, which the benchmark found clean on fast motion (#13).
@available(macOS 15.4, *)
final class FrameRateConverter: FrameInterpolating {
    private let processor = VTFrameProcessor()
    /// The later frame of the last pair. Sequential submission reuses what the engine worked out for it, so a pair
    /// that doesn't start there, the first one after a cut, goes in as random: sequential, it blended in the frame
    /// from before the cut.
    private var lastLater: CMTime?

    static var isSupported: Bool { VTFrameRateConversionConfiguration.isSupported }

    func start(size: PixelSize) throws -> FrameFormat {
        guard
            let configuration = VTFrameRateConversionConfiguration(
                frameWidth: size.width, frameHeight: size.height, usePrecomputedFlow: false,
                qualityPrioritization: .quality, revision: VTFrameRateConversionConfiguration.defaultRevision)
        else { throw MediaError.engineUnavailable }
        try processor.startSession(configuration: configuration)
        return FrameFormat(
            source: configuration.sourcePixelBufferAttributes,
            destination: configuration.destinationPixelBufferAttributes)
    }

    func interpolate(
        from earlier: TimedFrame, to later: TimedFrame, phases: [Float], into targets: [TimedFrame]
    )
        async throws
    {
        guard let source = VTFrameProcessorFrame(buffer: earlier.buffer, presentationTimeStamp: earlier.time),
            let next = VTFrameProcessorFrame(buffer: later.buffer, presentationTimeStamp: later.time)
        else { throw MediaError.exportFailed("Can't hand the frames over") }
        let destinations = targets.compactMap {
            VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: $0.time)
        }
        guard destinations.count == targets.count,
            let parameters = VTFrameRateConversionParameters(
                sourceFrame: source, nextFrame: next, opticalFlow: nil, interpolationPhase: phases,
                submissionMode: lastLater == earlier.time ? .sequential : .random, destinationFrames: destinations)
        else { throw MediaError.exportFailed("Can't hand the frames over") }
        lastLater = later.time
        try await processor.run(parameters)
    }

    func end() {
        processor.endSession()
    }
}

@available(macOS 15.4, *)
extension VTFrameProcessor {
    /// One `process(parameters:)` call, awaited.
    func run(_ parameters: any VTFrameProcessorParameters) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process(parameters: parameters) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
