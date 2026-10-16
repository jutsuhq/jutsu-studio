import Foundation

/// Network reachability. The engine pauses network work while offline.
public protocol Connectivity: Sendable {
    /// The current state first, then every change.
    func updates() -> AsyncStream<Bool>
}
