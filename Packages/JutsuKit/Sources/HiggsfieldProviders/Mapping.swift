import Foundation
import HiggsfieldCore
import JutsuCore

extension Cost {
    /// Server amounts are untrusted; a malformed quote must never look free or overflow variant pricing.
    static func serverCredits(_ value: Double, isEstimate: Bool = false, count: Int = 1) throws -> Cost {
        guard value >= 0, value < 1e12, let amount = Decimal(shortestOf: value) else {
            throw ProviderError.server(status: 200)
        }
        return .credits(amount * Decimal(count), isEstimate: isEstimate)
    }
}

extension ProviderError {
    /// A client failure in the engine's terms.
    init(_ error: HiggsfieldError) {
        self =
            switch error {
            case .unauthorized: .unauthorized
            case .insufficientFunds: .insufficientFunds
            case .concurrencyLimit(let max): .concurrencyLimit(max: max)
            case .validation(let field, let message): .validation(field: field, message: message)
            case .modelUnavailable: .modelUnavailable
            case .toolUnavailable: HiggsfieldMCPProvider.notAvailable
            case .server(let status): .server(status: status)
            case .network, .notSent: .network
            }
    }
}

extension RemoteStatus {
    init(_ status: GenerationStatus) {
        self =
            switch status {
            case .queued: .queued
            case .inProgress: .inProgress
            case .completed(let videoURL) where videoURL.isHTTPS: .completed(videoURL: videoURL)
            case .completed:
                .failed(message: String(localized: "The result isn't on a secure (https) address.", bundle: .module))
            case .failed(let message): .failed(message: message)
            case .rejected(let moderation): .rejected(Rejection(moderation))
            case .canceled: .canceled
            }
    }
}

extension Rejection {
    init(_ moderation: Moderation) {
        self =
            switch moderation {
            case .explicitContent: .explicitContent
            case .protectedContent: .protectedContent
            }
    }
}

/// Runs a client call and rethrows its `HiggsfieldError` as a `ProviderError`.
/// Anything else passes through untouched — notably `CancellationError`, which must never
/// become a failure the engine retries, and programmer errors, which must fail loudly
/// instead of masquerading as a server refusal.
func mapped<T: Sendable>(
    isolation: isolated (any Actor)? = #isolation, _ operation: () async throws -> T
) async throws -> T {
    do {
        return try await operation()
    } catch let error as HiggsfieldError {
        throw ProviderError(error)
    }
}
