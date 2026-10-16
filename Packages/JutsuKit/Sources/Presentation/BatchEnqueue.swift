import Foundation
import JutsuCore

/// Queues the specs of one submit in order and stops at the first failure. The jobs queued before it stay
/// queued and are paid for, so the alert says how many made it.
public enum BatchEnqueue {
    /// The alert for a failure, `nil` when every spec was queued.
    /// `kind` is the active connection, for the error's message.
    public static func run(
        _ specs: [JobSpec], kind: ProviderKind?, isolation: isolated (any Actor)? = #isolation,
        enqueue: (JobSpec) async throws -> Void
    ) async -> UserMessage? {
        var queued = 0
        do {
            for spec in specs {
                try await enqueue(spec)
                queued += 1
            }
            return nil
        } catch {
            return message(for: error, queued: queued, of: specs.count, kind: kind)
        }
    }

    /// The error's own alert while nothing was queued; once some jobs were, "2 of 3 jobs queued" with the
    /// error as the detail.
    static func message(for error: any Error, queued: Int, of total: Int, kind: ProviderKind?) -> UserMessage? {
        let failure = UserMessage(error, kind: kind)
        guard queued > 0 else { return failure }
        let reason =
            failure.map { "\($0.title). \($0.message)" }
            ?? String(localized: "The rest weren't queued.", bundle: .module)
        return UserMessage(
            title: String(localized: "\(queued) of \(total) jobs queued", bundle: .module), message: reason,
            action: failure?.action)
    }
}
