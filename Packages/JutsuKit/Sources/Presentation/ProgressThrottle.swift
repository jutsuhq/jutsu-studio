import Foundation

/// Lets through only the progress reports a percent bar would show differently: the first one, a change of the whole
/// percent, and a size becoming known or unknown (`nil`). A download reports every chunk written and an export
/// several times a second, and each report the UI keeps costs a hop to the main actor; asking this first, on the
/// reporting thread, keeps those hops to at most about a hundred.
public final class ProgressThrottle: @unchecked Sendable {
    // Safe: `last` is only touched under `lock`.
    private let lock = NSLock()
    /// The last percent let through: `.some(nil)` for an unknown size, `nil` before the first report.
    private var last: Int??

    public init() {}

    /// Whether to pass `fraction` (0…1, `nil` while the size is unknown) on.
    public func admits(_ fraction: Double?) -> Bool {
        let percent = fraction.map { Int(($0 * 100).rounded(.down)) }
        lock.lock()
        defer { lock.unlock() }
        if let last, last == percent { return false }
        last = .some(percent)
        return true
    }
}
