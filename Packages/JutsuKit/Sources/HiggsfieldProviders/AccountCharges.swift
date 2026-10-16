import Foundation
import HiggsfieldMCP
import JutsuCore

/// Finds what the account was charged for a finished job Higgsfield can't quote beforehand (a Topaz upscale:
/// "job_type 'topaz_video' does not support alpha v2 cost estimation", issue #113). A credit transaction names no
/// job, only what it was for and when (`CreditTransaction`), so the charge is matched by its name and time; anything
/// unclear leaves the price unknown rather than guessing.
enum AccountCharges {
    /// How far a charge may be from the job's run: the device's clock and the server's can differ, and the charge
    /// may be booked when the job is accepted or when it finishes.
    static let tolerance: TimeInterval = 120
    static let pageSize = 50
    /// Pages of the history read at most, newest first, before giving up.
    static let maxPages = 4

    /// From `tolerance` before the submit to `tolerance` after the job finished (or after the submit, when its end
    /// isn't known).
    static func window(submittedAt: Date, finishedAt: Date?) -> ClosedRange<Date> {
        let end = max(submittedAt, finishedAt ?? submittedAt)
        return submittedAt.addingTimeInterval(-tolerance)...end.addingTimeInterval(tolerance)
    }

    /// Whether a transaction's name says it was a Topaz video upscale. Higgsfield's wording isn't documented, and
    /// other charges read like "Higgsfield Genjutsu - Object Swap", so only the provider's name is relied on, in any
    /// case; a Topaz image upscale is told apart by "image".
    static func isTopazVideo(_ title: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return title.range(of: "topaz", options: options) != nil && title.range(of: "image", options: options) == nil
    }

    /// The credits of the one Topaz spend in `window`. `nil` when there is none, or when anything else named for
    /// Topaz is in the window too: a second spend (two upscales sent together can't be told apart) or a refund.
    static func credits(of transactions: [CreditTransaction], in window: ClosedRange<Date>) -> Double? {
        // Pages that overlap list the same transaction twice.
        let named = Set(transactions.filter { window.contains($0.date) && isTopazVideo($0.title) })
        guard named.count == 1, let charge = named.first, charge.action.lowercased() == "spend",
            charge.credits.isFinite, charge.credits != 0
        else { return nil }
        // Spent amounts are negative.
        return abs(charge.credits)
    }

    /// Whether a page reaching back to `oldest` may still be followed by transactions in `window`.
    static func readsOn(pastOldest oldest: Date?, window: ClosedRange<Date>) -> Bool {
        guard let oldest else { return false }
        return oldest >= window.lowerBound
    }
}

extension HiggsfieldMCPProvider {
    /// A Topaz upscale's charge, read from the account's credit history (`transactions`, read-only) once it has
    /// finished, and matched to it by `AccountCharges`. `nil` for any other job, one without a submit time, and when
    /// no single charge matches.
    public func charge(of job: Job) async throws -> Cost? {
        guard job.spec.operation?.action.isPricedAfterRun == true, let submittedAt = job.submittedAt else {
            return nil
        }
        let window = AccountCharges.window(submittedAt: submittedAt, finishedAt: job.chargedAt)
        var transactions: [CreditTransaction] = []
        var cursor: JSONValue?
        var seenCursors: Set<JSONValue> = []
        for _ in 0..<AccountCharges.maxPages {
            let page = try await mapped {
                try await account.transactions(cursor: cursor, size: AccountCharges.pageSize)
            }
            transactions += page.items
            // Newest first: a page that reaches back past the window is the last one needed.
            guard let next = page.nextCursor, seenCursors.insert(next).inserted,
                AccountCharges.readsOn(pastOldest: page.items.last?.date, window: window)
            else { break }
            cursor = next
        }
        guard let credits = AccountCharges.credits(of: transactions, in: window) else { return nil }
        // Up, as every server price.
        return try? Cost.serverCredits(credits)
    }
}
