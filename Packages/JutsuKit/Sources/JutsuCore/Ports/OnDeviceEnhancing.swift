import Foundation

/// Enhance on this Mac (`OnDeviceAction`): free, no account, no upload. MediaKit runs it on VideoToolbox.
public protocol OnDeviceEnhancing: Sendable {
    /// Whether this Mac has the engine. Asks the system only whether it is supported, never about its model, which
    /// asking would start downloading.
    func supports(_ engine: OnDeviceEngine) -> Bool

    /// Whether the engine's model is known to be on this Mac. Asking may start macOS's download of it and builds a
    /// configuration, so `OnDeviceRuns` asks only off the main actor once a run on the engine ended, after the person
    /// agreed to the download (`OnDeviceEngine.downloadsModel`).
    func modelIsReady(_ engine: OnDeviceEngine) -> Bool

    /// Makes `action`'s result from the file at `source`, written to `output`. Canceling or failing leaves nothing at
    /// `output`.
    func run(
        _ action: OnDeviceAction, on source: URL, to output: URL,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput
}

extension OnDeviceEnhancing {
    public func modelIsReady(_ engine: OnDeviceEngine) -> Bool { false }
}
