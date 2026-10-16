import Foundation
import HiggsfieldCore

// `virality_predictor` as a live run on 2026-10-15 showed it (issue #111). `action: "create"` with
// `params: {model: "virality_predictor", medias: [{role: "video", id}]}`, the video a confirmed upload's `media_id`
// or a finished generation's job ID, answers `{job_id, model: "virality_predictor", poll_interval: 1.5}` and costs
// nothing. That job is polled with `job_status`: its `generation` has `model: "brain_activity"`, `type: "image"`,
// `params.analysis` (`null` until the job completes) and an HTML dashboard in `results.rawUrl`. The readings are in
// `params.analysis.scores` (`overall_score`, `viral_potential`, `hook_score` over the first 3 s, `brain_engagement`
// and `sustain` on 0–100; `peak_second`, `peak_frame_index`, and `peak_score` on 0–1), beside
// `global_scores_by_frame`, `regions`, `timeline` and `score_details` (`disclaimer`, `normalization`,
// `hook_window_seconds`). `analysis.summary` has an `overall_score` of its own that differs from `scores`'; it is
// not read. `jobs_wait` reports the job too, but without `params`, so only `job_status` gives the readings.

/// What the Virality Predictor said about a video.
public struct ViralityPrediction: Sendable, Hashable {
    /// `scores.overall_score`, 0–100.
    public var overall: Double?
    /// `scores.viral_potential`, 0–100.
    public var viralPotential: Double?
    /// `scores.hook_score`, 0–100, over the first 3 seconds.
    public var hook: Double?
    /// `scores.brain_engagement`, 0–100.
    public var engagement: Double?
    /// `scores.sustain`, 0–100.
    public var sustain: Double?
    /// `scores.peak_second`: when the video reads strongest.
    public var peakSecond: Double?
    /// `global_scores_by_frame`, one reading per frame of `timeline`, on the server's own scale.
    public var perFrame: [Double]
    /// `score_details.disclaimer`.
    public var disclaimer: String?
    /// The job's HTML dashboard (`results.rawUrl`, HTTPS only).
    public var dashboardURL: URL?

    public init(
        overall: Double? = nil, viralPotential: Double? = nil, hook: Double? = nil, engagement: Double? = nil,
        sustain: Double? = nil, peakSecond: Double? = nil, perFrame: [Double] = [], disclaimer: String? = nil,
        dashboardURL: URL? = nil
    ) {
        self.overall = overall
        self.viralPotential = viralPotential
        self.hook = hook
        self.engagement = engagement
        self.sustain = sustain
        self.peakSecond = peakSecond
        self.perFrame = perFrame
        self.disclaimer = disclaimer
        self.dashboardURL = dashboardURL
    }
}

/// The job one `virality_predictor` call started.
public struct ViralityJob: Sendable, Hashable {
    public var id: String
    /// How long to wait between polls, in seconds, when the answer says (`poll_interval`).
    public var pollInterval: Double?

    public init(id: String, pollInterval: Double? = nil) {
        self.id = id
        self.pollInterval = pollInterval
    }
}

/// Where a Virality Predictor job stands.
public enum ViralityStatus: Sendable, Hashable {
    case running
    /// `nil` when the completed job has no `params.analysis.scores`.
    case completed(ViralityPrediction?)
    case failed(message: String?)
}

extension ViralityPrediction {
    static let analysis = "analysis"
    static let scores = "scores"

    /// A completed `job_status` `generation`; `nil` without `params.analysis.scores`.
    init?(generation: JSONValue) {
        let analysis = generation[ToolKey.params]?[Self.analysis]
        guard let scores = analysis?[Self.scores], scores.objectValue != nil else { return nil }
        func percent(_ key: String) -> Double? {
            scores[key]?.numberValue.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
        }
        self.init(
            overall: percent("overall_score"), viralPotential: percent("viral_potential"), hook: percent("hook_score"),
            engagement: percent("brain_engagement"), sustain: percent("sustain"),
            peakSecond: scores["peak_second"]?.numberValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            perFrame: (analysis?["global_scores_by_frame"]?.arrayValue ?? []).compactMap {
                $0.numberValue.flatMap { $0.isFinite ? $0 : nil }
            },
            disclaimer: analysis?["score_details"]?["disclaimer"]?.stringValue,
            dashboardURL: generation[ToolKey.results]?[ToolKey.rawURL]?.stringValue.flatMap(URL.init(serverMedia:)))
    }
}

extension HiggsfieldAccount {
    /// The fixed `params.model` the tool requires.
    static let viralityModel = "virality_predictor"
    static let pollInterval = "poll_interval"

    /// `action: "create"` on a finished generation, named by its job ID as the video.
    static func viralityArguments(jobID: String) -> [String: JSONValue] {
        [
            ToolKey.action: "create",
            ToolKey.params: [
                ToolKey.model: .string(viralityModel),
                ToolKey.medias: [[ToolKey.role: .string(ToolKey.video), ToolKey.id: .string(jobID)]],
            ],
        ]
    }

    /// Starts scoring a finished generation; free, so a resend costs nothing. Throws
    /// `HiggsfieldError.toolUnavailable`, without a call, when the account has no `virality_predictor`; a refusal
    /// (`isError`, or an answer with an `error` or without a `job_id`) throws `.validation`.
    public func predictVirality(jobID: String) async throws -> ViralityJob {
        _ = try await viralityTool()
        let value = try await call(.viralityPredictor, Self.viralityArguments(jobID: jobID))
        guard let id = value[ToolKey.jobIDSingle]?.stringValue, !id.isEmpty else {
            throw HiggsfieldError.validation(
                field: nil,
                message: value[ToolKey.error]?.stringValue ?? "Unexpected result from the virality_predictor tool")
        }
        return ViralityJob(
            id: id, pollInterval: value[Self.pollInterval]?.numberValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
    }

    /// `job_status` of a Virality Predictor job, with its readings once it completed.
    public func viralityStatus(of jobID: String) async throws -> ViralityStatus {
        let value = try await call(.status, [ToolKey.jobID: .string(jobID)])
        guard let generation = value[ToolKey.generation] else { throw unexpected(.status) }
        return Self.viralityStatus(of: generation, error: value[ToolKey.error])
    }

    /// A completed job reads its analysis rather than requiring `rawUrl` as a video does; any other status reads as
    /// `status(of:)` does, a rejection or cancel as a failure.
    static func viralityStatus(of generation: JSONValue, error: JSONValue? = nil) -> ViralityStatus {
        if generation[ToolKey.status] == "completed" { return .completed(ViralityPrediction(generation: generation)) }
        switch status(of: generation, error: error) {
        case .failed(let message)?: return .failed(message: message)
        case .rejected?, .canceled?: return .failed(message: nil)
        case .queued?, .inProgress?, .completed?, nil: return .running
        }
    }

    private func viralityTool() async throws -> MCPTool {
        guard let tool = try await lookUp(.viralityPredictor, recheckingAfter: Self.optionalToolRecheck) else {
            throw HiggsfieldError.toolUnavailable(ToolRole.viralityPredictor.rawValue)
        }
        return tool
    }
}
