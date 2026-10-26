import Foundation
import JutsuCore

// The line under a Queue row's meta: why a job stopped, failed or was not charged.

extension JobRowModel {
    static func note(
        _ state: JobState, providerKind: ProviderKind, charged: Bool, rejection: Rejection? = nil,
        retrying: RetryStatus? = nil, agentHold: AgentHold? = nil
    ) -> Note? {
        switch state {
        case .failed(let reason):
            return Note(
                text: [reason.text, charged ? String(localized: "charged", bundle: .module) : notCharged]
                    .joined(separator: " · "), role: .danger)
        case .rejected:
            let title = rejection?.title ?? String(localized: "Rejected by content moderation", bundle: .module)
            return Note(text: "\(title) · \(notCharged)", role: .warning)
        case .canceled:
            return Note(
                text: charged
                    ? String(localized: "Download canceled · charged", bundle: .module)
                    : String(localized: "Not charged", bundle: .module), role: .faint)
        case .paused(let reason):
            if reason == .agentLimit { return agentNote(agentHold) }
            return pausedNote(reason, providerKind: providerKind, retrying: retrying)
        default:
            return nil
        }
    }

    private static func pausedNote(_ reason: PauseReason, providerKind: ProviderKind, retrying: RetryStatus?) -> Note {
        switch reason {
        case .insufficientFunds:
            return Note(
                text: providerKind == .account
                    ? String(localized: "Out of plan credits · top up, then resume", bundle: .module)
                    : String(localized: "Not enough API balance · top up, then resume", bundle: .module),
                role: .warning)
        case .connectionNeedsAttention:
            return Note(
                text: String(localized: "Connection needs attention · sign in again, then resume", bundle: .module),
                role: .warning)
        case .priceAboveCap:
            return Note(
                text: String(
                    localized: "Price from Higgsfield goes over today's spending cap · confirm to resume",
                    bundle: .module), role: .warning)
        case .notEnoughDiskSpace:
            return Note(
                text: String(
                    localized: "Not enough disk space to save the result · free up space, then resume",
                    bundle: .module), role: .warning)
        case .agentLimit:
            return agentNote(nil)
        case .byUser:
            return Note(
                text: String(localized: "Paused by you · nothing is submitted until you resume", bundle: .module),
                role: .faint)
        case .keptFailing:
            guard let retrying else {
                return Note(
                    text: String(
                        localized: "Kept failing before it was sent · not charged, resume to try again",
                        bundle: .module),
                    role: .warning)
            }
            let cause = retryCause(retrying.cause)
            return Note(
                text: String(
                    localized: "Kept failing before it was sent (\(cause)) · not charged, resume to try again",
                    bundle: .module),
                role: .warning)
        }
    }

    /// Why the spending guard stopped an agent's job; only the person resumes it.
    static func agentNote(_ hold: AgentHold?) -> Note {
        let text =
            switch hold {
            case .unknownPrice?:
                String(localized: "An agent's job at a price not known yet · confirm to send it", bundle: .module)
            case .overMaxCost?:
                String(localized: "Costs more than the agent was allowed · confirm to send it", bundle: .module)
            case .overDailyBudget?:
                String(localized: "Over today's agent budget · confirm to send it", bundle: .module)
            case .ledgerUnavailable?:
                String(
                    localized: "Agent spending couldn't be read · nothing was sent, confirm to send it", bundle: .module
                )
            case .unlimitedNotAllowed?:
                String(
                    localized: """
                        Would use your plan's unlimited generations, which agents may not use · confirm to send it
                        """, bundle: .module)
            case .aboveApprovedPrice?:
                String(localized: "Costs more now than the price you approved · confirm to send it", bundle: .module)
            case nil:
                String(localized: "Stopped by the agent spending limits · confirm to send it", bundle: .module)
            }
        return Note(text: text, role: .warning)
    }

    private static var notCharged: String { String(localized: "not charged", bundle: .module) }

    /// "Retrying in 30 s · attempt 4 · last error: Higgsfield server error (HTTP 502)", while a failed step waits
    /// to run again; "Retrying" once the wait is over and the step runs.
    static func retryNote(_ retrying: RetryStatus, now: Date) -> Note {
        let attempt = retrying.failures + 1
        let cause = retryCause(retrying.cause)
        let wait = retrying.nextAttemptAt.timeIntervalSince(now).rounded(.up)
        let text =
            wait > 0
            ? String(
                localized: "Retrying in \(spoken(wait)) · attempt \(attempt) · last error: \(cause)", bundle: .module)
            : String(localized: "Retrying · attempt \(attempt) · last error: \(cause)", bundle: .module)
        return Note(text: text, role: .warning)
    }

    static func retryCause(_ cause: RetryStatus.Cause) -> String {
        switch cause {
        case .network:
            String(localized: "no connection to Higgsfield", bundle: .module)
        case .server(let status) where status >= 500:
            String(localized: "Higgsfield server error (HTTP \(status))", bundle: .module)
        case .server(let status):
            String(localized: "Higgsfield answered HTTP \(status)", bundle: .module)
        case .modelUnavailable:
            String(localized: "the model is unavailable on Higgsfield", bundle: .module)
        case .concurrencyLimit:
            String(localized: "all of the account's slots on Higgsfield are busy", bundle: .module)
        case .insufficientFunds:
            String(localized: "not enough credits on Higgsfield", bundle: .module)
        }
    }
}
