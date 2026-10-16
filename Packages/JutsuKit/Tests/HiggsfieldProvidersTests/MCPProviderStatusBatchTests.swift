import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// `jobs_wait` through the provider: one call for up to 12 jobs, and `nil` (each job polled alone) whenever the
    /// tool is missing, fails or answers in a shape that can't be read.
    @Suite struct ProviderStatusBatch {
        static let jobsWait = tool("jobs_wait", "Wait for up to 12 jobs", ["jobs", "timeout_seconds"])
        static let jobs = [RemoteJob(requestID: "job-1"), RemoteJob(requestID: "job-2")]

        static func jobsWaitCalls(_ stub: StubServer) -> Int {
            Provider.calls(stub).filter { $0["name"] == "jobs_wait" }.count
        }

        /// The MCP stub, except that every `jobs_wait` call gets `response(request)`.
        static func provider(
            jobsWait response: @escaping @Sendable (RecordedRequest) -> StubResponse
        ) -> (HiggsfieldMCPProvider, StubServer) {
            let mcp = mcpServer(tools: Provider.fullSet + [jobsWait])
            let stub = StubServer { request, _ in
                request.json?["params"]?["name"] == "jobs_wait" ? response(request) : mcp.respond(to: request)
            }
            return (makeProvider(stub.session()), stub)
        }

        @Test func oneCallAnswersEveryJob() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet + [Self.jobsWait]) { name, _ in
                name == "jobs_wait"
                    ? [
                        "jobs": [
                            [
                                "index": 0, "job_id": "job-1", "status": "completed",
                                "result_url": "https://cdn.example/1.mp4",
                            ],
                            ["index": 1, "job_id": "job-2", "status": "in_progress"],
                        ],
                        "poll_after_seconds": 4, "all_terminal": false,
                    ] : [:]
            }

            let batch = try #require(try await provider.statuses(of: Self.jobs))

            let output = try #require(URL(string: "https://cdn.example/1.mp4"))
            #expect(
                batch
                    == BatchStatus(
                        statuses: ["job-1": .completed(videoURL: output), "job-2": .inProgress], pollAfter: 4))
            #expect(provider.statusBatchLimit == 12)
            #expect(Provider.calls(stub).map { $0["name"] } == ["jobs_wait"])
            #expect(
                Provider.calls(stub).first?["arguments"] == [
                    "jobs": [["job_id": "job-1", "index": 0], ["job_id": "job-2", "index": 1]]
                ])
        }

        @Test func withoutJobsWaitEachJobIsPolledAlone() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet)
            #expect(try await provider.statuses(of: Self.jobs) == nil)
            #expect(Self.jobsWaitCalls(stub) == 0)
        }

        @Test func aFailedCallFallsBackThisTimeOnly() async throws {
            let (provider, stub) = Self.provider { _ in StubResponse(status: 500) }
            #expect(try await provider.statuses(of: Self.jobs) == nil)
            #expect(try await provider.statuses(of: Self.jobs) == nil)
            #expect(Self.jobsWaitCalls(stub) == 2)
        }

        @Test func aToolErrorFallsBack() async throws {
            let (provider, _) = Self.provider { request in
                .json([
                    "jsonrpc": "2.0", "id": request.json?["id"] ?? .null,
                    "error": ["code": -32000, "message": "jobs_wait is busy"],
                ])
            }
            #expect(try await provider.statuses(of: Self.jobs) == nil)
        }

        @Test func anUnreadableAnswerStopsUsingTheTool() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet + [Self.jobsWait]) { name, _ in
                name == "jobs_wait" ? ["state": ["job-1": "done"]] : [:]
            }
            #expect(try await provider.statuses(of: Self.jobs) == nil)
            #expect(try await provider.statuses(of: Self.jobs) == nil)
            #expect(Self.jobsWaitCalls(stub) == 1)
        }
    }
}
