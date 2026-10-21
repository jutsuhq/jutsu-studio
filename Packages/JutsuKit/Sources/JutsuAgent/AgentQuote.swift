import Foundation

/// What a video would cost now, before anything is uploaded or queued.
public struct AgentQuote: Codable, Equatable, Sendable {
    /// nil when no price list or quote says.
    public var price: AgentAmount?
    /// The provider's price or an exact list price; false for an estimate, which Higgsfield refines after upload.
    public var isExact: Bool
    public var mode: String
    public var model: String
    public var resolution: String
    /// Seconds the result runs.
    public var duration: Double
    /// What is left of today's agent budget; nil while nothing is connected.
    public var remainingToday: Int?
    /// It would be paid from the plan's unlimited generations, as the person's Use unlimited generations and the
    /// account's allowance stand now: it counts nothing against the budget, and it runs without the person only while
    /// they let agents use unlimited generations (`capabilities` budget.unlimitedAllowed).
    public var paysUnlimited: Bool
    /// What `create_video` would refuse it for now, in English; nil when it would queue it.
    public var blocker: String?
    /// The most `variants` takes for this request; 1 with `variantsUnavailable` saying why.
    public var maxVariants: Int
    /// Why it makes one video whatever `variants` asks, in English; nil when more are offered.
    public var variantsUnavailable: String?

    public init(
        price: AgentAmount?, isExact: Bool, mode: String, model: String, resolution: String, duration: Double,
        remainingToday: Int?, paysUnlimited: Bool = false, blocker: String?, maxVariants: Int = 1,
        variantsUnavailable: String? = nil
    ) {
        self.paysUnlimited = paysUnlimited
        self.price = price
        self.isExact = isExact
        self.mode = mode
        self.model = model
        self.resolution = resolution
        self.duration = duration
        self.remainingToday = remainingToday
        self.blocker = blocker
        self.maxVariants = maxVariants
        self.variantsUnavailable = variantsUnavailable
    }
}
