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
    /// What an estimate (`isExact` false) means for the job, in English; nil for an exact price or none.
    public var priceNote: String?
    /// The most `variants` takes for this request; 1 with `variantsUnavailable` saying why.
    public var maxVariants: Int
    /// Why it makes one video whatever `variants` asks, in English; nil when more are offered.
    public var variantsUnavailable: String?
    /// The reference images the job has, elements' included, and how many its model takes in this mode: the
    /// server's constraints where they state them, else the app's built-in limits.
    public var images: Int
    public var minImages: Int
    public var maxImages: Int
    /// The result's frame: `source` when it keeps the source clip's orientation, `model` when the model takes no
    /// aspect ratio and picks the frame itself (`frameNote` says what to check), else the ratio asked for (16:9,
    /// 9:16, auto…); nil for a model that takes none.
    public var aspectRatio: String?
    /// What to check when the model may answer in another frame than the source's, in English; nil otherwise.
    public var frameNote: String?

    public init(
        price: AgentAmount?, isExact: Bool, mode: String, model: String, resolution: String, duration: Double,
        remainingToday: Int?, paysUnlimited: Bool = false, blocker: String?, priceNote: String? = nil,
        maxVariants: Int = 1, variantsUnavailable: String? = nil, images: Int = 0, minImages: Int = 0,
        maxImages: Int = 0, aspectRatio: String? = nil, frameNote: String? = nil
    ) {
        self.aspectRatio = aspectRatio
        self.frameNote = frameNote
        self.paysUnlimited = paysUnlimited
        self.price = price
        self.isExact = isExact
        self.mode = mode
        self.model = model
        self.resolution = resolution
        self.duration = duration
        self.remainingToday = remainingToday
        self.blocker = blocker
        self.priceNote = priceNote
        self.maxVariants = maxVariants
        self.variantsUnavailable = variantsUnavailable
        self.images = images
        self.minImages = minImages
        self.maxImages = maxImages
    }

    /// What `create_video` would pause the job for, as far as a quote can tell before upload: the plan's unlimited
    /// generations agents may not use, a price not known yet, or one above what is left of today's agent budget
    /// (`remaining`). An estimate isn't a blocker: the guard checks the price Higgsfield quotes before the submit.
    public static func blocker(price: Int?, remaining: Int?, paysUnlimited: Bool, unlimitedAllowed: Bool) -> String? {
        if paysUnlimited {
            return unlimitedAllowed
                ? nil
                : "It would be paid from the plan's unlimited generations, which the person hasn't let agents use "
                    + "(Settings › Agents); the job would wait for the person."
        }
        guard let price else {
            return "The price isn't known before upload; unless Higgsfield quotes it then, the job waits for the "
                + "person."
        }
        if let remaining, price > remaining {
            return "It costs more than is left of today's agent budget (\(remaining)); the job would wait for the "
                + "person."
        }
        return nil
    }

    /// `priceNote` for a price that is an estimate; nil for an exact one, none, or one the plan's unlimited
    /// generations pay.
    public static func priceNote(isEstimate: Bool, hasPrice: Bool, paysUnlimited: Bool) -> String? {
        guard isEstimate, hasPrice, !paysUnlimited else { return nil }
        return "An estimate from the model's rate per second. Higgsfield quotes the exact price before the job is "
            + "sent (once its source is uploaded); the job then runs on its own when that price is within max_cost, "
            + "what is left of today's agent budget and the person's daily cap, and waits for the person only when "
            + "it is above one of them."
    }
}
