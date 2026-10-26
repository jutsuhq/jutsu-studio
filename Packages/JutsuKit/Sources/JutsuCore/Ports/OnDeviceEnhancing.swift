import Foundation

/// Enhance on this Mac (`OnDeviceAction`): free, no account, no upload. MediaKit runs it on VideoToolbox.
public protocol OnDeviceEnhancing: Sendable {
    /// Whether this Mac has the engine. Asks the system only whether it is supported, never about its model, which
    /// asking would start downloading.
    func supports(_ engine: OnDeviceEngine) -> Bool

    /// Makes `action`'s result from the file at `source`, written to `output`. Canceling or failing leaves nothing at
    /// `output`.
    func run(
        _ action: OnDeviceAction, on source: URL, to output: URL,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> OnDeviceOutput
}
