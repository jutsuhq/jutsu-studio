import Foundation

/// What a virality prediction said about one result. Stored on the job (`Job.virality`), so a result is never scored
/// again without the user asking. Scores stored before the live answer was known carry other keys, which are ignored.
public struct ViralityScore: Codable, Sendable, Hashable {
    /// The overall score, 0–100; `nil` when the provider only linked a report.
    public var score: Int?
    /// 0–100.
    public var viralPotential: Int?
    /// How strongly the first 3 seconds hold attention, 0–100.
    public var hook: Int?
    /// 0–100.
    public var engagement: Int?
    /// How well attention holds over the whole video, 0–100.
    public var sustain: Int?
    /// When the video reads strongest, in seconds from its start.
    public var peakSecond: Double?
    /// One reading per frame, on the provider's own scale; empty or `nil` when it gave none.
    public var perFrame: [Double]?
    /// What the provider says the scores are and aren't.
    public var disclaimer: String?
    /// The provider's dashboard of the report.
    public var reportURL: URL?
    public var scoredAt: Date

    public init(
        score: Int? = nil, viralPotential: Int? = nil, hook: Int? = nil, engagement: Int? = nil, sustain: Int? = nil,
        peakSecond: Double? = nil, perFrame: [Double]? = nil, disclaimer: String? = nil, reportURL: URL? = nil,
        scoredAt: Date
    ) {
        self.score = score
        self.viralPotential = viralPotential
        self.hook = hook
        self.engagement = engagement
        self.sustain = sustain
        self.peakSecond = peakSecond
        self.perFrame = perFrame
        self.disclaimer = disclaimer
        self.reportURL = reportURL
        self.scoredAt = scoredAt
    }
}

/// The answer of one scoring call.
public struct ViralityOutcome: Sendable, Hashable {
    /// `nil` when the answer couldn't be read; the call may still have been charged.
    public var score: ViralityScore?
    /// What the provider says it charged; `nil` when it doesn't say.
    public var charged: Cost?

    public init(score: ViralityScore?, charged: Cost?) {
        self.score = score
        self.charged = charged
    }
}

/// A provider that predicts how well a finished result of its own account will do: hook, sustain and engagement.
/// Named by the result's job ID, so nothing is uploaded.
public protocol ViralityScoring: Sendable {
    /// The price of scoring one result; `nil` when the provider gives no quote.
    func viralityEstimate(jobID: String) async throws -> Cost?
    /// Scores one result, waiting until the provider has. Throws `ProviderError.outcomeUnknown` when a paid call may
    /// have reached the provider without an answer, any other `ProviderError` when it was refused or failed.
    func scoreVirality(jobID: String) async throws -> ViralityOutcome
}
