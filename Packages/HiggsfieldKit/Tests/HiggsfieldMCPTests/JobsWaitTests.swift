import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `jobs_wait` answers in the shape of the tool's `outputSchema` (catalog snapshot of 2026-10-15; no answer seen yet),
/// and in the other shapes read tolerantly.
enum JobsWaitFixture {
    static let answer: JSONValue = [
        "jobs": [
            [
                "index": 0, "job_id": "job-1", "status": "completed", "type": "video", "model": "seedance_2_5",
                "result_url": "https://cdn.example/1.mp4", "thumbnail_url": "https://cdn.example/1.jpg",
            ],
            ["index": 1, "job_id": "job-2", "status": "in_progress"],
            ["index": 2, "job_id": "job-3", "status": "failed", "error": "Bad input"],
        ],
        "summary": ["total": 3, "completed": 1, "failed": 1, "active": 1, "errors": 0],
        "all_terminal": false, "poll_after_seconds": 5, "timed_out": true,
    ]
}

@Suite struct JobsWaitDecoding {
    static let asked: Set<String> = ["job-1", "job-2", "job-3"]

    @Test func theSchemasShapeIsRead() throws {
        let wait = JobsWait(answer: JobsWaitFixture.answer, asked: Self.asked)
        let output = try #require(URL(string: "https://cdn.example/1.mp4"))
        #expect(
            wait
                == JobsWait(
                    statuses: [
                        "job-1": .completed(videoURL: output), "job-2": .inProgress,
                        "job-3": .failed(message: "Bad input"),
                    ], pollAfterSeconds: 5))
    }

    @Test func otherShapesAreReadToo() throws {
        let nested: JSONValue = [
            "results": [
                ["job_id": "job-1", "generation": ["status": "nsfw"]], ["jobId": "job-2", "status": "queued"],
                ["id": "job-3", "status": "completed", "results": ["rawUrl": "https://cdn.example/3.mp4"]],
            ]
        ]
        #expect(
            JobsWait(answer: nested, asked: Self.asked).statuses == [
                "job-1": .rejected(.explicitContent), "job-2": .queued,
                "job-3": .completed(videoURL: try #require(URL(string: "https://cdn.example/3.mp4"))),
            ])

        let byID: JSONValue = ["jobs": ["job-1": ["status": "canceled"], "job-9": ["status": "queued"]]]
        #expect(JobsWait(answer: byID, asked: Self.asked).statuses == ["job-1": .canceled])
    }

    @Test func jobsThatCantBeReadAreLeftOut() {
        let answer: JSONValue = [
            "jobs": [
                ["job_id": "job-1", "status": "completed"],  // no file
                ["job_id": "job-2", "state": "completed"],  // no status
                ["job_id": "job-3", "status": "completed", "result_url": "http://cdn.example/3.mp4"],
                ["job_id": "job-4", "status": "queued"],  // not asked for
                ["status": "queued"],  // no ID
            ],
            "poll_after_seconds": -1,
        ]
        #expect(JobsWait(answer: answer, asked: Self.asked) == JobsWait(statuses: [:]))
    }

    /// The server couldn't look these up, for now or for good: `job_status` is asked instead.
    @Test func failedLookupsAreLeftOut() {
        let answer: JSONValue = [
            "jobs": [
                ["index": 0, "job_id": "job-1", "status": "lookup_failed", "retryable": true],
                ["index": 1, "job_id": "job-2", "status": "lookup_failed", "retryable": false, "error": "Not found"],
                ["index": 2, "job_id": "job-3", "status": "queued"],
            ],
            "all_terminal": false,
        ]
        #expect(JobsWait(answer: answer, asked: Self.asked).statuses == ["job-3": .queued])
    }

    static let junk: [JSONValue] = [
        .null, "done", 42, [], [:], ["jobs": "job-1"], ["jobs": [1, 2]], ["status": "completed"],
        ["poll_after_seconds": "5"], ["all_terminal": "yes"],
    ]

    @Test(arguments: junk)
    func junkReadsAsNothing(answer: JSONValue) {
        #expect(JobsWait(answer: answer, asked: Self.asked) == JobsWait(statuses: [:]))
    }
}

extension Network {
    @Suite struct JobsWaitCalls {
        /// The tool's arguments as the catalog snapshot of 2026-10-15 lists them.
        static let jobsWait = tool(
            "jobs_wait", "Long-poll 1-12 generation jobs together without opening a widget",
            ["jobs", "timeout_seconds"])

        @Test func sendsEachIDWithItsIndexAndReadsTheAnswer() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.jobsWait]) { _, _ in
                JobsWaitFixture.answer
            }

            let wait = try #require(try await account.waitForJobs(["job-1", "job-2", "job-3"]))

            #expect(wait.statuses.count == 3)
            #expect(wait.pollAfterSeconds == 5)
            let calls = Account.calls(stub)
            #expect(calls.map { $0["name"] } == ["jobs_wait"])
            #expect(
                calls.first?["arguments"] == [
                    "jobs": [
                        ["job_id": "job-1", "index": 0], ["job_id": "job-2", "index": 1],
                        ["job_id": "job-3", "index": 2],
                    ]
                ])
        }

        @Test func withoutJobsWaitThereIsNoAnswer() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet)
            #expect(try await account.waitForJobs(["job-1"]) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        /// The first guess (#94) took plain IDs under `job_ids`; a schema without `jobs` counts as no tool.
        @Test func aSchemaWithoutJobsIsNotCalled() async throws {
            let other = tool("jobs_wait", "Wait", ["job_ids"])
            let (account, stub) = Account.account(tools: Account.fullSet + [other])
            #expect(try await account.waitForJobs(["job-1"]) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        @Test func noneOrMoreThanTwelveJobsAreNotCalled() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.jobsWait])
            #expect(try await account.waitForJobs([]) == nil)
            #expect(try await account.waitForJobs((0...12).map { "job-\($0)" }) == nil)
            #expect(Account.calls(stub).isEmpty)
        }
    }
}
