import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Virality scores (issues #45, #111), against the answers of a live run on 2026-10-15 with synthetic IDs and
    /// URLs: `create` starts a free job, whose `job_status` carries the readings once it completes.
    @Suite struct ViralityProvider {
        static let predictor = (try? CatalogSnapshot.tool("virality_predictor")) ?? [:]
        static let videoID = "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"
        static let jobID = "7d2e9b41-0c3a-4f6e-8b12-5a9c0d1e2f34"
        static let dashboard = "https://cdn.example/virality/hf_20261015_job.html"
        static let disclaimer = "Predictive proxy metrics, not guaranteed performance or clinical measures."

        /// `poll_interval` is 0 here so the test doesn't wait; the live answer said 1.5.
        static let created: JSONValue = ["job_id": .string(jobID), "model": "virality_predictor", "poll_interval": 0]

        static func generation(_ status: String, analysis: JSONValue = .null, error: String? = nil) -> JSONValue {
            [
                "generation": [
                    "id": .string(jobID), "type": "image", "status": .string(status), "model": "brain_activity",
                    "params": [
                        "medias": [["role": "video", "data": ["id": .string(videoID)]]], "analysis": analysis,
                    ],
                    "results": status == "completed" ? ["rawUrl": .string(dashboard)] : .null,
                    "error": error.map(JSONValue.string) ?? .null,
                ]
            ]
        }

        static let analysis: JSONValue = [
            "scores": [
                "sustain": 100, "hook_score": 29, "peak_score": .number(0.42), "peak_second": 12, "overall_score": 46,
                "viral_potential": 45, "brain_engagement": 39, "peak_frame_index": 12,
            ],
            "summary": ["overall_score": 39, "sustain_score": 100],
            "score_details": ["disclaimer": .string(disclaimer), "hook_window_seconds": [0, 3]],
            "global_scores_by_frame": [.number(0.2), .number(0.42), .number(0.3)],
        ]

        /// The stub answers `create` with `created`, then each `job_status` with the next of `statuses`, the last
        /// one repeated.
        static func provider(statuses: [JSONValue], create: JSONValue = created) -> (HiggsfieldMCPProvider, StubServer)
        {
            let answers = Answers(statuses)
            return Provider.provider(tools: Provider.fullSet + [predictor]) { name, _ in
                switch name {
                case "virality_predictor": create
                case "job_status": answers.next()
                default: [:]
                }
            }
        }

        @Test func theAccountOffersScores() {
            #expect(HiggsfieldMCPProvider.offersVirality)
        }

        @Test func scoringIsFreeAndAsksNothing() async throws {
            let (provider, stub) = Self.provider(statuses: [Self.generation("queued")])
            #expect(try await provider.viralityEstimate(jobID: Self.videoID) == .credits(0, isEstimate: false))
            #expect(Provider.calls(stub).isEmpty)
        }

        @Test func theJobIsPolledUntilItCompletesAndItsScoresKept() async throws {
            let (provider, stub) = Self.provider(statuses: [
                Self.generation("queued"), Self.generation("in_progress"),
                Self.generation("completed", analysis: Self.analysis),
            ])

            let outcome = try await provider.scoreVirality(jobID: Self.videoID)

            let score = try #require(outcome.score)
            #expect(score.score == 46)
            #expect(score.viralPotential == 45)
            #expect(score.hook == 29)
            #expect(score.engagement == 39)
            #expect(score.sustain == 100)
            #expect(score.peakSecond == 12)
            #expect(score.perFrame == [0.2, 0.42, 0.3])
            #expect(score.disclaimer == Self.disclaimer)
            #expect(score.reportURL == URL(string: Self.dashboard))
            #expect(outcome.charged == .credits(0, isEstimate: false))
            let calls = Provider.calls(stub)
            #expect(
                calls.filter { $0["name"] == "virality_predictor" }.map { $0["arguments"] } == [
                    [
                        "action": "create",
                        "params": [
                            "model": "virality_predictor",
                            "medias": [["role": "video", "id": .string(Self.videoID)]],
                        ],
                    ]
                ])
            #expect(
                calls.filter { $0["name"] == "job_status" }.map { $0["arguments"] }
                    == Array(repeating: ["jobId": .string(Self.jobID)], count: 3))
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func aCompletedJobWithoutScoresKeepsNone() async throws {
            let (provider, _) = Self.provider(statuses: [Self.generation("completed")])
            let outcome = try await provider.scoreVirality(jobID: Self.videoID)
            #expect(outcome.score == nil)
            #expect(outcome.charged == .credits(0, isEstimate: false))
        }

        @Test func aFailedJobOrARefusalIsAValidationError() async throws {
            let (failing, _) = Self.provider(statuses: [Self.generation("failed", error: "Video is too long")])
            await #expect(throws: ProviderError.validation(field: nil, message: "Video is too long")) {
                try await failing.scoreVirality(jobID: Self.videoID)
            }

            let (refusing, _) = Self.provider(statuses: [], create: ["error": "Too long"])
            await #expect(throws: ProviderError.validation(field: nil, message: "Too long")) {
                try await refusing.scoreVirality(jobID: Self.videoID)
            }
        }

        @Test func aJobThatNeverEndsGivesUp() async throws {
            let (provider, stub) = Self.provider(statuses: [Self.generation("in_progress")])
            await #expect(throws: ProviderError.validation(field: nil, message: AccountVirality.timedOut)) {
                try await provider.scoreVirality(jobID: Self.videoID)
            }
            #expect(Provider.calls(stub).filter { $0["name"] == "job_status" }.count == AccountVirality.maximumPolls)
        }

        @Test func thePauseFollowsTheAnswerWithinBounds() {
            #expect(AccountVirality.pause(nil) == .seconds(1.5))
            #expect(AccountVirality.pause(3) == .seconds(3))
            #expect(AccountVirality.pause(120) == .seconds(10))
        }
    }
}
