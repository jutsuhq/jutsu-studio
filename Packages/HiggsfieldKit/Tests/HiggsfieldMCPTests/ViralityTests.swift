import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// The answers of a live Virality Predictor run on 2026-10-15 (issue #111), with synthetic IDs and URLs.
enum ViralityFixture {
    static let videoID = "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"
    static let jobID = "7d2e9b41-0c3a-4f6e-8b12-5a9c0d1e2f34"
    static let dashboard = "https://cdn.example/virality/hf_20261015_job.html"
    static let disclaimer = "Predictive proxy metrics, not guaranteed performance or clinical measures."

    static let created: JSONValue = [
        "job_id": .string(jobID), "model": "virality_predictor", "poll_interval": .number(1.5),
    ]

    static func generation(status: String, analysis: JSONValue = .null, results: JSONValue = .null) -> JSONValue {
        [
            "generation": [
                "id": .string(jobID), "type": "image", "status": .string(status), "model": "brain_activity",
                "params": [
                    "prompt": "",
                    "medias": [["role": "video", "data": ["id": .string(videoID), "type": "video_input"]]],
                    "video_meta": ["duration": 12], "analysis": analysis,
                ],
                "results": results,
            ]
        ]
    }

    static let analysis: JSONValue = [
        "scores": [
            "sustain": 100, "hook_score": 29, "peak_score": .number(0.42), "peak_second": 12, "overall_score": 46,
            "viral_potential": 45, "brain_engagement": 39, "peak_frame_index": 12,
        ],
        "summary": ["overall_score": 39, "sustain_score": 100],
        "regions": [
            [
                "id": "visual", "title": "Visual", "subtitle": "Visual cortex", "mean_score": .number(0.31),
                "peak_score": .number(0.5), "peak_second": 4, "lower_better": false,
                "values_by_frame": [.number(0.1), .number(0.5), .number(0.3)],
            ]
        ],
        "timeline": [
            "frame_count": 3, "time_seconds": [0, 1, 2], "duration_seconds": 12, "captions_by_frame": ["", "", ""],
        ],
        "score_details": [
            "disclaimer": .string(disclaimer),
            "normalization": "scores are normalized prediction proxies in range 0..100", "hook_window_seconds": [0, 3],
        ],
        "global_scores_by_frame": [.number(0.2), .number(0.42), .number(0.3)],
    ]

    static let completed = generation(status: "completed", analysis: analysis, results: ["rawUrl": .string(dashboard)])
}

extension Network {
    @Suite struct Virality {
        static func tools() throws -> [JSONValue] {
            Account.fullSet + [try CatalogSnapshot.tool("virality_predictor")]
        }

        @Test func createNamesTheVideoAsTheSchemaSaysAndReadsTheJob() async throws {
            let (account, stub) = Account.account(tools: try Self.tools()) { _, _ in ViralityFixture.created }

            let job = try await account.predictVirality(jobID: ViralityFixture.videoID)

            #expect(job == ViralityJob(id: ViralityFixture.jobID, pollInterval: 1.5))
            #expect(
                Account.calls(stub) == [
                    [
                        "name": "virality_predictor",
                        "arguments": [
                            "action": "create",
                            "params": [
                                "model": "virality_predictor",
                                "medias": [["role": "video", "id": .string(ViralityFixture.videoID)]],
                            ],
                        ],
                    ]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aRunningJobHasNoAnalysisYet() async throws {
            let (account, stub) = Account.account(tools: try Self.tools()) { _, _ in
                ViralityFixture.generation(status: "in_progress")
            }

            #expect(try await account.viralityStatus(of: ViralityFixture.jobID) == .running)
            #expect(Account.calls(stub).first?["arguments"] == ["jobId": .string(ViralityFixture.jobID)])
        }

        @Test func aCompletedJobReadsTheScoresNotTheSummary() async throws {
            let (account, _) = Account.account(tools: try Self.tools()) { _, _ in ViralityFixture.completed }

            let status = try await account.viralityStatus(of: ViralityFixture.jobID)

            #expect(
                status
                    == .completed(
                        ViralityPrediction(
                            overall: 46, viralPotential: 45, hook: 29, engagement: 39, sustain: 100, peakSecond: 12,
                            perFrame: [0.2, 0.42, 0.3], disclaimer: ViralityFixture.disclaimer,
                            dashboardURL: URL(string: ViralityFixture.dashboard))))
        }

        @Test func aCompletedJobWithoutScoresHasNoPrediction() {
            let generation = ViralityFixture.generation(
                status: "completed", results: ["rawUrl": .string(ViralityFixture.dashboard)])["generation"]
            #expect(HiggsfieldAccount.viralityStatus(of: generation ?? .null) == .completed(nil))
        }

        @Test func aFailedOrRejectedJobFails() {
            let failed: JSONValue = ["status": "failed", "error": "Video too long"]
            #expect(HiggsfieldAccount.viralityStatus(of: failed) == .failed(message: "Video too long"))
            #expect(HiggsfieldAccount.viralityStatus(of: ["status": "nsfw"]) == .failed(message: nil))
            #expect(HiggsfieldAccount.viralityStatus(of: ["status": "queued"]) == .running)
        }

        @Test func anErrorWithoutAJobIsARefusal() async throws {
            let (account, _) = Account.account(tools: try Self.tools()) { _, _ in
                ["error": "Video is longer than 15 seconds"]
            }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Video is longer than 15 seconds")) {
                try await account.predictVirality(jobID: ViralityFixture.videoID)
            }
        }

        @Test func aMissingToolIsReportedWithoutACall() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet)
            await #expect(throws: HiggsfieldError.toolUnavailable("virality_predictor")) {
                try await account.predictVirality(jobID: ViralityFixture.videoID)
            }
            #expect(Account.calls(stub).isEmpty)
        }
    }
}
