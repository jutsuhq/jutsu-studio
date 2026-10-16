import Foundation

/// A submitted job as the provider knows it.
public struct RemoteJob: Codable, Sendable, Hashable {
    public var requestID: String
    /// Server-side trace ID, kept for support requests; `nil` when the provider doesn't return one.
    public var correlationID: String?
    /// Where the provider said to poll and cancel; `nil` when it didn't say. Check the origin before use.
    public var statusURL: URL?
    public var cancelURL: URL?
    /// What the submit answer said about the job, when it said anything. Not stored.
    public var initialStatus: RemoteStatus?
    /// The submit was sent to be paid from the plan's unlimited allowance (`JobSpec.usesUnlimited`), and the
    /// answer didn't say it cost credits. Not stored: the engine keeps it in the job's spec.
    public var paidWithUnlimited = false
    /// What the submit answer says the job costs, when it says so; `nil` otherwise. Not stored: the engine keeps
    /// it as the job's server price.
    public var charged: Cost?
    /// The other jobs the same submit started, one per further variant (`JobSpec.variants`), in the answer's
    /// order; each of them is paid for. Not stored: the engine makes each one a job of its own.
    public var variants: [RemoteJob] = []
    /// The submit asked for Seedance's native draft on the account (`draft: true`), so this job, once completed,
    /// can be finalized at 1080p by its ID within seven days (`JobSpec.draftJobID`). Stored; `false` in jobs stored
    /// before it existed.
    public var isNativeDraft = false

    public init(
        requestID: String, correlationID: String? = nil, statusURL: URL? = nil, cancelURL: URL? = nil,
        initialStatus: RemoteStatus? = nil
    ) {
        self.requestID = requestID
        self.correlationID = correlationID
        self.statusURL = statusURL
        self.cancelURL = cancelURL
        self.initialStatus = initialStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        correlationID = try container.decodeIfPresent(String.self, forKey: .correlationID)
        statusURL = try container.decodeIfPresent(URL.self, forKey: .statusURL)
        cancelURL = try container.decodeIfPresent(URL.self, forKey: .cancelURL)
        isNativeDraft = try container.decodeIfPresent(Bool.self, forKey: .isNativeDraft) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, correlationID, statusURL, cancelURL, isNativeDraft
    }
}
