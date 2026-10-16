import Foundation
import HiggsfieldCore
import Testing

@testable import HiggsfieldMCP

/// A Genjutsu Style job as a live run on 2026-10-15 showed it (issue #21), with synthetic IDs and URLs.
@Suite struct StyleJobTests {
    static let presetID = "0b6f2c4e-8a1d-4e3f-9b2a-6c5d4e3f2a1b"

    static func job(status: String, type: String, results: JSONValue = .null) -> JSONValue {
        [
            "id": "job-1", "type": .string(type), "status": .string(status), "model": "restyle",
            "params": [
                "preset_id": .string(presetID), "resolution": "480p", "duration": 12, "bitrate_mode": "high",
                "generate_audio": false,
                "medias": [["role": "video", "data": ["id": "media-1", "url": "https://cdn.example/in.mp4"]]],
            ],
            "results": results,
        ]
    }

    @Test func executePresetsAnswerGivesItsFirstJobID() {
        let answer: JSONValue = [
            "source": "marketing_studio", "preset_id": .string("genjutsu-style:\(Self.presetID)"),
            "job_ids": ["job-1", "job-2"], "status": "submitted",
        ]
        #expect(PresetQuote.jobID(in: answer) == "job-1")
        #expect(PresetQuote.jobID(in: ["job_id": "job-9", "job_ids": ["job-1"]]) == "job-1")
    }

    @Test func aRunningStyleJobIsAnImageAndStillReadsAsRunning() throws {
        #expect(HiggsfieldAccount.status(of: Self.job(status: "queued", type: "image")) == .queued)
        #expect(HiggsfieldAccount.status(of: Self.job(status: "in_progress", type: "image")) == .inProgress)
        let output = try #require(URL(string: "https://cdn.example/out.mp4"))
        let done = Self.job(status: "completed", type: "video", results: ["rawUrl": .string(output.absoluteString)])
        #expect(HiggsfieldAccount.status(of: done) == .completed(videoURL: output))
    }

    @Test func jobsWaitReadsARunningStyleJobToo() throws {
        let answer: JSONValue = [
            "jobs": [
                ["index": 0, "job_id": "job-1", "status": "in_progress", "type": "image", "model": "restyle"],
                [
                    "index": 1, "job_id": "job-2", "status": "completed", "type": "video", "model": "restyle",
                    "result_url": "https://cdn.example/2.mp4",
                ],
            ]
        ]
        let output = try #require(URL(string: "https://cdn.example/2.mp4"))
        #expect(
            JobsWait(answer: answer, asked: ["job-1", "job-2"]).statuses
                == ["job-1": .inProgress, "job-2": .completed(videoURL: output)])
    }
}
