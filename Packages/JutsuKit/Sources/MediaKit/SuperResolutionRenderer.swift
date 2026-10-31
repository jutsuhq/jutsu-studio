import CoreMedia
import CoreVideo
import Foundation
import JutsuCore
import VideoToolbox

/// Makes a frame 4× larger: VideoToolbox's super resolution, or a stand-in in tests.
protocol FrameScaling: AnyObject {
    /// Starts the engine for frames of `size`, first downloading its model when macOS doesn't have it yet, and says
    /// the frames it takes and gives.
    func start(size: PixelSize, modelProgress: @escaping @Sendable (Double) -> Void) async throws -> FrameFormat
    /// Fills `target` with `frame` 4× larger. `previous` is the frame before and what it became, which the video kind
    /// uses to keep detail steady; `nil` for the first frame and after a cut, where nothing carries over.
    func scale(
        _ frame: TimedFrame, previous: (source: TimedFrame, output: TimedFrame)?, into target: TimedFrame)
        async throws
    func end()
}

/// Upscale › On this Mac for a video: every frame 4× larger, or scaled down from that to `target`, the sound as it
/// is. A portrait frame the scaler refuses is turned a quarter for it and back (`OnDeviceUpscale.plan`). At a hard
/// cut (`CutDetector`) the scaler starts afresh, so detail from the shot before doesn't carry into the next.
enum SuperResolutionRenderer {
    /// On the frame loop's own thread (`FrameLoop`).
    static func renderVideo(
        source url: URL, to output: URL, scaler: some FrameScaling, target: OnDeviceUpscale.Target = .full,
        limit: PixelSize = OnDeviceUpscale.scalerLimit, progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        try await FrameLoop.run {
            try await renderFrames(
                source: url, to: output, scaler: scaler, target: target, limit: limit, progress: progress)
        }
    }

    private static func renderFrames(
        source url: URL, to output: URL, scaler: some FrameScaling, target: OnDeviceUpscale.Target, limit: PixelSize,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        let source = try await FrameSource.load(url)
        guard OnDeviceUpscale.offersVideo(source.naturalSize),
            let plan = OnDeviceUpscale.plan(for: source.naturalSize, limit: limit)
        else { throw MediaError.engineUnavailable }
        guard let size = target.output(for: source.naturalSize) else { throw Self.targetNotLarger }
        let format = try await scaler.start(size: plan.scalerInput) { progress(.downloadingModel($0)) }
        defer { scaler.end() }
        let pipeline = try await FramePipeline(
            source, to: output, pixelFormat: format.pixelFormat, size: size, frameRate: source.frameRate,
            keepsAudio: true)
        let frames = try ScalerFrames(plan: plan, format: format)
        let resizer = size == plan.output ? nil : try FrameResizer(to: size, attributes: format.destination)
        let expected = max(1, Int((source.duration * source.frameRate).rounded()))
        let luma = LumaSampler()
        var previous: (source: TimedFrame, output: TimedFrame)?
        var previousLuma: [UInt8] = []
        var done = 0
        try pipeline.start()
        do {
            while let frame = try pipeline.nextFrame() {
                try Task.checkCancellation()
                let frameLuma = luma.thumbnail(of: frame.buffer)
                if CutDetector.isCut(previousLuma, frameLuma) { previous = nil }
                previousLuma = frameLuma
                let input = try frames.toScaler(frame)
                let scaled = TimedFrame(buffer: try frames.scaled.make(), time: frame.time)
                try await scaler.scale(input, previous: previous, into: scaled)
                previous = (input, scaled)
                let upscaled = try frames.fromScaler(scaled)
                try await pipeline.append(try resizer?.resize(upscaled) ?? upscaled)
                done += 1
                progress(.working(min(Double(done) / Double(expected), 1)))
            }
            try await pipeline.finish()
        } catch {
            pipeline.cancel()
            throw error
        }
        return OnDeviceOutput(pixelSize: source.displaySize(of: size), duration: source.duration, fileExtension: "mp4")
    }

    static let targetNotLarger = MediaError.exportFailed("The upscale target isn't larger than the source")
}

/// Scales the scaler's 4× frames down to a smaller target with VideoToolbox's pixel transfer, into frames of the
/// target's size.
private final class FrameResizer {
    private let session: VTPixelTransferSession
    private let pool: FramePool

    init(to size: PixelSize, attributes: [String: any Sendable]) throws {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session
        else { throw MediaError.exportFailed("Can't scale the frames") }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        self.session = session
        pool = try FramePool(size: size, attributes: attributes)
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    func resize(_ frame: TimedFrame) throws -> TimedFrame {
        let buffer = try pool.make()
        let status = VTPixelTransferSessionTransferImage(session, from: frame.buffer, to: buffer)
        guard status == noErr else { throw MediaError.exportFailed("Can't scale a frame (\(status))") }
        return TimedFrame(buffer: buffer, time: frame.time)
    }
}

/// The frames around the scaler: turned a quarter into it and back out of it when the plan says so.
private struct ScalerFrames {
    /// What the scaler writes into: the output's size, or its turned size.
    let scaled: FramePool
    private let turned: Turned?

    private struct Turned {
        let input: FramePool
        let output: FramePool
        let toScaler = try? FrameRotator(.clockwise)
        let back = try? FrameRotator(.counterclockwise)
    }

    init(plan: OnDeviceUpscale.Plan, format: FrameFormat) throws {
        let scale = OnDeviceUpscale.scale
        let scaledSize = PixelSize(
            width: plan.scalerInput.width * scale, height: plan.scalerInput.height * scale)
        scaled = try FramePool(size: scaledSize, attributes: format.destination)
        turned =
            plan.rotates
            ? Turned(
                input: try FramePool(size: plan.scalerInput, attributes: format.source),
                output: try FramePool(size: plan.output, attributes: format.destination)) : nil
    }

    func toScaler(_ frame: TimedFrame) throws -> TimedFrame {
        guard let turned else { return frame }
        return try Self.turn(frame, with: turned.toScaler, into: turned.input)
    }

    func fromScaler(_ frame: TimedFrame) throws -> TimedFrame {
        guard let turned else { return frame }
        return try Self.turn(frame, with: turned.back, into: turned.output)
    }

    private static func turn(
        _ frame: TimedFrame, with rotator: FrameRotator?, into pool: FramePool
    ) throws
        -> TimedFrame
    {
        guard let rotator else { throw MediaError.exportFailed("Can't turn the frames") }
        let buffer = try pool.make()
        try rotator.rotate(frame.buffer, into: buffer)
        return TimedFrame(buffer: buffer, time: frame.time)
    }
}

/// Turns frames a quarter with VideoToolbox's pixel rotation.
final class FrameRotator {
    enum Turn {
        case clockwise
        case counterclockwise
    }

    private let session: VTPixelRotationSession

    init(_ turn: Turn) throws {
        var session: VTPixelRotationSession?
        guard VTPixelRotationSessionCreate(nil, &session) == noErr,
            let session
        else { throw MediaError.exportFailed("Can't turn the frames") }
        let rotation = turn == .clockwise ? kVTRotation_CW90 : kVTRotation_CCW90
        VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_Rotation, value: rotation)
        self.session = session
    }

    deinit {
        VTPixelRotationSessionInvalidate(session)
    }

    func rotate(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let status = VTPixelRotationSessionRotateImage(session, source, destination)
        guard status == noErr else { throw MediaError.exportFailed("Can't turn a frame (\(status))") }
    }
}

/// VideoToolbox's super resolution, 4×. Setting it up for a size, or asking about its model, starts macOS's one-time
/// download of the model, so `OnDeviceRuns` starts it only once the person has agreed.
@available(macOS 26, *)
final class SuperResolutionScaler: FrameScaling {
    private let inputType: VTSuperResolutionScalerConfiguration.InputType
    private let processor = VTFrameProcessor()

    /// Never touches a model: only whether this Mac has the engine and its 4× factor.
    static var isSupported: Bool {
        VTSuperResolutionScalerConfiguration.isSupported
            && VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(OnDeviceUpscale.scale)
    }

    init(inputType: VTSuperResolutionScalerConfiguration.InputType) {
        self.inputType = inputType
    }

    /// Whether the model is here. Reading it may start macOS's download, so only once the person agreed.
    static func modelIsReady(inputType: VTSuperResolutionScalerConfiguration.InputType) -> Bool {
        let size = OnDeviceUpscale.scalerLimit
        return VTSuperResolutionScalerConfiguration(
            frameWidth: size.width, frameHeight: size.height, scaleFactor: OnDeviceUpscale.scale, inputType: inputType,
            usePrecomputedFlow: false, qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        )?.configurationModelStatus == .ready
    }

    func start(size: PixelSize, modelProgress: @escaping @Sendable (Double) -> Void) async throws -> FrameFormat {
        guard
            let configuration = VTSuperResolutionScalerConfiguration(
                frameWidth: size.width, frameHeight: size.height, scaleFactor: OnDeviceUpscale.scale,
                inputType: inputType, usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision)
        else { throw MediaError.engineUnavailable }
        try await Self.downloadModel(of: configuration, progress: modelProgress)
        try processor.startSession(configuration: configuration)
        return FrameFormat(
            source: configuration.sourcePixelBufferAttributes,
            destination: configuration.destinationPixelBufferAttributes)
    }

    func scale(
        _ frame: TimedFrame, previous: (source: TimedFrame, output: TimedFrame)?, into target: TimedFrame
    )
        async throws
    {
        let isVideo = inputType == .video
        guard let source = VTFrameProcessorFrame(buffer: frame.buffer, presentationTimeStamp: frame.time),
            let destination = VTFrameProcessorFrame(buffer: target.buffer, presentationTimeStamp: target.time)
        else { throw MediaError.exportFailed("Can't hand the frame over") }
        let before = previous.flatMap {
            VTFrameProcessorFrame(buffer: $0.source.buffer, presentationTimeStamp: $0.source.time)
        }
        let beforeOutput = previous.flatMap {
            VTFrameProcessorFrame(buffer: $0.output.buffer, presentationTimeStamp: $0.output.time)
        }
        guard
            let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: source, previousFrame: isVideo ? before : nil,
                previousOutputFrame: isVideo ? beforeOutput : nil, opticalFlow: nil,
                submissionMode: isVideo && previous != nil ? .sequential : .random, destinationFrame: destination)
        else { throw MediaError.exportFailed("Can't hand the frame over") }
        try await processor.run(parameters)
    }

    func end() {
        processor.endSession()
    }

    /// How long the model may still read as missing after its download finished, while macOS puts it in place.
    static let modelSettling: Duration = .seconds(10)

    /// Waits for the model, reporting how much of it is here twice a second. Asks macOS for it only when it isn't
    /// on its way already: one download macOS started on its own (making the configuration can) is waited for until
    /// it is ready, or asked for again if it stopped. A download that finished is given `modelSettling` to read as
    /// ready before the run fails.
    private static func downloadModel(
        of configuration: VTSuperResolutionScalerConfiguration, progress: @Sendable (Double) -> Void
    ) async throws {
        var outcome: DownloadOutcome?
        var downloaded: ContinuousClock.Instant?
        // A model already here reports nothing, so the card doesn't flash the download.
        var waited = false
        while true {
            switch configuration.configurationModelStatus {
            case .ready:
                if waited { progress(1) }
                return
            case .downloadRequired:
                if let result = outcome?.result {
                    try result.get()
                    let finished = downloaded ?? .now
                    downloaded = finished
                    if ContinuousClock.now - finished > modelSettling {
                        throw MediaError.exportFailed("macOS didn't finish downloading the upscale model")
                    }
                }
                if outcome == nil {
                    let started = DownloadOutcome()
                    beginDownload(of: configuration, into: started)
                    outcome = started
                }
            default:
                break
            }
            if let result = outcome?.result { try result.get() }
            waited = true
            progress(Double(configuration.configurationModelPercentageAvailable))
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Not async, so the wait above can poll the progress while the download runs.
    private static func beginDownload(
        of configuration: VTSuperResolutionScalerConfiguration, into outcome: DownloadOutcome
    ) {
        configuration.downloadConfigurationModel { error in outcome.finish(error) }
    }
}

/// How the model download ended, set from VideoToolbox's completion handler.
private final class DownloadOutcome: @unchecked Sendable {
    // Safe: `stored` is only touched under `lock`.
    private let lock = NSLock()
    private var stored: Result<Void, any Error>?

    var result: Result<Void, any Error>? { lock.withLock { stored } }

    func finish(_ error: (any Error)?) {
        lock.withLock { stored = error.map { .failure($0) } ?? .success(()) }
    }
}
