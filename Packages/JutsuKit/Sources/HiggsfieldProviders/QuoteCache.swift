import Foundation

/// Free quotes asked before upload, one per key for as long as the connection lasts: a second estimate of the same
/// job, even while the first is out, reads the same answer. A failed quote isn't kept, so a later estimate asks again.
actor QuoteCache<Key: Hashable & Sendable, Value: Sendable> {
    private var quotes: [Key: Task<Value, any Error>] = [:]

    /// The quote for `key`, asked with `ask` unless it was asked already. Rethrows the failure of `ask`.
    func value(for key: Key, ask: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task: Task<Value, any Error>
        if let asked = quotes[key] {
            task = asked
        } else {
            task = Task { try await ask() }
            quotes[key] = task
        }
        do {
            return try await task.value
        } catch {
            if quotes[key] == task { quotes[key] = nil }
            throw error
        }
    }
}
