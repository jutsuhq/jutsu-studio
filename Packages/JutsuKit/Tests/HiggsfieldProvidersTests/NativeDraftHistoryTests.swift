import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// A native Seedance draft and its finalize in the account's history (issue #115): `show_generations` echoes
    /// `draft` and `draft_job_id` in each job's params.
    @Suite struct NativeDraftHistory {
        /// A trimmed `show_generations` page: the paid run's draft (`draft: true`, 480p) and a finalize of it.
        static let page = #"""
            {
              "items": [
                {
                  "id": "final-job",
                  "type": "video",
                  "status": "completed",
                  "model": "seedance_2_5",
                  "createdAt": 1791200000,
                  "liked": false,
                  "results": {"rawUrl": "https://example.com/final.mp4"},
                  "params": {
                    "prompt": "a fox in the snow",
                    "resolution": "1080p",
                    "draft": false,
                    "draft_job_id": "draft-job"
                  }
                },
                {
                  "id": "draft-job",
                  "type": "video",
                  "status": "completed",
                  "model": "seedance_2_5",
                  "createdAt": 1791100000,
                  "liked": false,
                  "results": {"rawUrl": "https://example.com/draft.mp4"},
                  "params": {
                    "prompt": "a fox in the snow",
                    "mode": "omni_reference",
                    "resolution": "480p",
                    "aspect_ratio": "9:16",
                    "duration": 15,
                    "width": 480,
                    "height": 854,
                    "draft": true,
                    "draft_job_id": null,
                    "medias": [
                      {"role": "image", "data": {"id": "image-1", "type": "media_input", "url": "https://example.com/a.png"}}
                    ]
                  }
                }
              ],
              "next_cursor": null
            }
            """#

        static func history() async throws -> [HistoryItem] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(Self.page.utf8))
            let (provider, _) = Provider.provider(tools: Provider.fullSet + [History.generations]) { name, _ in
                name == "show_generations" ? value : [:]
            }
            return try await provider.history(after: nil).items
        }

        @Test func aDraftFromHistoryIsImportedAsANativeDraft() async throws {
            let items = try await Self.history()
            let draft = try #require(items.first { $0.id == "draft-job" })
            #expect(draft.isNativeDraft && draft.draftJobID == nil)

            let job = Job(importing: draft, owner: "owner-1", importedAt: Date(timeIntervalSince1970: 1_791_200_000))
            #expect(job.spec.isDraft && job.spec.resolution == .p480)
            #expect(job.remote?.isNativeDraft == true)
            // The finalize window counts from here (`Job.finalizeDeadline`, tested in Presentation).
            #expect(job.chargedAt == Date(timeIntervalSince1970: 1_791_100_000))
        }

        /// A finalize keeps the draft's job ID; history gives no other link to the draft.
        @Test func aFinalizeFromHistoryKeepsItsDraftsID() async throws {
            let items = try await Self.history()
            let final = try #require(items.first { $0.id == "final-job" })
            #expect(!final.isNativeDraft && final.draftJobID == "draft-job")

            let job = Job(importing: final, owner: "owner-1", importedAt: Date(timeIntervalSince1970: 1_791_200_000))
            #expect(!job.spec.isDraft && job.spec.draftJobID == "draft-job")
            #expect(job.remote?.isNativeDraft == false)
        }

        /// Only Seedance 2.5 has the native draft: another model's `draft` isn't read.
        @Test func otherModelsAreNoNativeDrafts() {
            let generation = PastGeneration(
                id: "job-1", type: "video", status: "completed", model: "hf_mult_motion_control",
                createdAt: Date(timeIntervalSince1970: 0), outputURL: URL(string: "https://example.com/out.mp4"),
                media: [PastMedia(role: .video, id: "video-1", url: URL(string: "https://example.com/in.mp4"))])
            var draft = generation
            draft.isDraft = true
            #expect(HistoryMapping.item(draft)?.isNativeDraft == false)
        }
    }
}
