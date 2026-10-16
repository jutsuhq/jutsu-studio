import Foundation

/// Time source of the engine; tests swap in a clock that doesn't really wait.
public protocol EngineClock: Sendable {
    var now: Date { get }
    /// Throws `CancellationError` when the calling task is canceled.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: EngineClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
