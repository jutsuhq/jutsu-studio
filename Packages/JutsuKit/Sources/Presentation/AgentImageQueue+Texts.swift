import Foundation
import JutsuCore

// The list price the guard falls back on, and the texts a held or failed request shows.
extension AgentImageQueue {
    /// The model's list price for the request, an estimate.
    static func listPrice(of record: AgentImageRecord) -> Cost? {
        switch record.model.listPrice {
        case .usd(let amount, _)?: .usd(amount * Decimal(record.count), isEstimate: true)
        case .credits(let amount, _)?: .credits(amount * Decimal(record.count), isEstimate: true)
        case nil: nil
        }
    }

    /// Why a held request waits, for its row in the Queue and its tile in Create: the reason in the words a held video
    /// job's row gives it (`JobRowModel.note`), then what an image request's row offers, Review… and then Send, where
    /// a video job's row has Confirm.
    public static func text(of hold: AgentImageRecord.Hold) -> String {
        switch hold {
        case .agent(.unknownPrice):
            String(localized: "An agent's job at a price not known yet · review to send it", bundle: .module)
        case .agent(.overMaxCost):
            String(localized: "Costs more than the agent was allowed · review to send it", bundle: .module)
        case .agent(.overDailyBudget):
            String(localized: "Over today's agent budget · review to send it", bundle: .module)
        case .agent(.ledgerUnavailable):
            String(
                localized: "Agent spending couldn't be read · nothing was sent, review to send it", bundle: .module)
        case .agent(.unlimitedNotAllowed):
            String(
                localized: """
                    Would use your plan's unlimited generations, which agents may not use · review to send it
                    """, bundle: .module)
        case .agent(.aboveApprovedPrice):
            String(localized: "Costs more now than the price you approved · review to send it", bundle: .module)
        case .priceAboveCap:
            String(
                localized: "Price from Higgsfield goes over today's spending cap · review to send it", bundle: .module)
        }
    }

    static let notRecorded = String(localized: "Jutsu Studio lost the record of this request.", bundle: .module)
    static let lostAnswer = String(
        localized: "Jutsu Studio quit while sending this request, so it may have been sent. Its price still counts.",
        bundle: .module)
}
