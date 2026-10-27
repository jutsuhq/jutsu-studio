import Foundation
import JutsuCore
import VideoToolbox

/// Enhance on this Mac with VideoToolbox's frame processors (`OnDeviceEnhancing`).
public struct OnDeviceEnhancer: OnDeviceEnhancing {
    public init() {}

    public func supports(_ engine: OnDeviceEngine) -> Bool {
        switch engine {
        case .frameRateConversion:
            guard #available(macOS 15.4, *) else { return false }
            return FrameRateConverter.isSupported
        case .videoSuperResolution:
            guard #available(macOS 26, *) else { return false }
            return SuperResolutionScaler.isSupported
        }
    }

    public func run(
        _ action: OnDeviceAction, on source: URL, to output: URL,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput {
        do {
            guard supports(action.engine) else { throw MediaError.engineUnavailable }
            switch action {
            case .smoothMotion(let motion):
                guard #available(macOS 15.4, *) else { throw MediaError.engineUnavailable }
                return try await SmoothMotionRenderer.render(
                    motion, source: source, to: output, interpolator: FrameRateConverter(), progress: progress)
            case .upscaleVideo:
                guard #available(macOS 26, *) else { throw MediaError.engineUnavailable }
                return try await SuperResolutionRenderer.renderVideo(
                    source: source, to: output, scaler: SuperResolutionScaler(inputType: .video), progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
