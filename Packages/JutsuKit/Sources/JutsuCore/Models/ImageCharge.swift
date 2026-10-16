import Foundation

/// The price of one reference image request (`ImageProvider`), of one character sheet request
/// (`CharacterSheetMaker`), or of scoring one result's virality (`ViralityScoring`). Neither is a `Job`, so the daily cap and Spending count these beside the jobs. A request counts from its submit: while it runs, like a job in flight,
/// and once it finished with images, on the day it was sent. One that failed, was refused or was cancelled while
/// queued isn't charged and is dropped.
public struct ImageCharge: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// When the request was submitted.
    public var date: Date
    public var cost: Cost
    public var providerKind: ProviderKind
    /// The model's title, for Spending.
    public var model: String
    /// Images or sheets asked for, or results scored.
    public var images: Int
    /// Not finished yet. Still set after a quit, since the request may have finished and been charged since: it
    /// keeps counting then, on the day it was sent.
    public var isPending: Bool
    /// What was paid for; `nil` in charges stored before virality scores existed, which are reference images.
    public var purpose: Purpose?

    public enum Purpose: String, Codable, Sendable, Hashable {
        case referenceImages
        case viralityScore
        case characterSheets
    }

    public init(
        id: UUID = UUID(), date: Date, cost: Cost, providerKind: ProviderKind, model: String, images: Int,
        isPending: Bool = true, purpose: Purpose? = nil
    ) {
        self.id = id
        self.date = date
        self.cost = cost
        self.providerKind = providerKind
        self.model = model
        self.images = images
        self.isPending = isPending
        self.purpose = purpose
    }

    /// `purpose`, reading a charge stored without one as reference images.
    public var paidFor: Purpose { purpose ?? .referenceImages }
}

extension Budget {
    /// What the image requests in `charges` add to `committed(_:on:in:calendar:)` on `day`: the ones sent that day,
    /// and every one still running.
    public static func committed(
        _ charges: [ImageCharge], on day: Date, in unit: Capabilities.CostUnit, calendar: Calendar = .current
    ) -> Decimal {
        charges.reduce(Decimal(0)) { total, charge in
            guard charge.cost.unit == unit, charge.isPending || calendar.isDate(charge.date, inSameDayAs: day) else {
                return total
            }
            return total + charge.cost.amount
        }
    }
}
