import Foundation
import Testing

@testable import JutsuAgent

@Suite struct VideoCommandTests {
    private func error(_ json: String) -> AgentError? {
        if case .failure(let error) = AgentWire.request(from: Data(json.utf8)).request { error } else { nil }
    }

    @Test func everyVideoCommandRoundTrips() throws {
        let video = AgentVideoRequest(
            mode: "motion_transfer", model: "seedance25", prompt: "dance",
            source: AgentSource(path: "/tmp/a.mov", end: 5),
            images: ["/tmp/b.png"], resolution: "720p", draft: true, length: nil, audio: "mute", variants: 2)
        let commands: [AgentCommand] = [
            .quote(QuoteCommand(video: AgentVideoRequest(mode: "restyle", imageCount: 2, style: UUID()))),
            .createVideo(
                CreateVideoCommand(
                    requestID: "r-1", fingerprint: String(repeating: "b", count: 64), video: video,
                    maxCost: AgentAmount(250, .usdCents))),
            .jobs(JobsCommand(ids: [UUID()], waitSeconds: 50)), .jobs(JobsCommand(limit: 5)),
            .jobAction(JobActionCommand(action: .cancel, job: UUID())),
            .jobAction(JobActionCommand(action: .pauseQueue)),
        ]
        for command in commands {
            let line = try AgentWire.line(AgentRequest(command, id: "1"))
            #expect(try AgentWire.request(from: line.dropLast()).request.get().command == command)
        }
    }

    /// Numbers are checked before anything formats or computes with them.
    @Test func outOfRangeFieldsAreBadRequests() {
        let fingerprint = String(repeating: "a", count: 64)
        let base = #""version":1,"command":"create_video","requestId":"r","fingerprint":"\#(fingerprint)""#
        let lines = [
            #"{\#(base),"video":{"mode":"restyle"},"maxCost":{"amount":-1,"unit":"usd_cents"}}"#,
            #"{\#(base),"video":{"mode":"restyle"},"maxCost":{"amount":100000000,"unit":"usd_cents"}}"#,
            #"{\#(base),"video":{"mode":"restyle"},"maxCost":{"amount":1e30,"unit":"credits"}}"#,
            #"{\#(base),"video":{"mode":"restyle","source":{"end":1e300}},"maxCost":{"amount":1,"unit":"credits"}}"#,
            #"{\#(base),"video":{"mode":"restyle","source":{"start":4,"end":2}},"maxCost":{"amount":1,"unit":"credits"}}"#,
            #"{\#(base),"video":{"mode":"restyle","variants":99},"maxCost":{"amount":1,"unit":"credits"}}"#,
            #"{\#(base),"video":{"mode":"nope"},"maxCost":{"amount":1,"unit":"credits"}}"#,
            #"{"version":1,"command":"create_video","requestId":"../x","fingerprint":"\#(fingerprint)","video":{"mode":"restyle"},"maxCost":{"amount":1,"unit":"credits"}}"#,
            #"{"version":1,"command":"jobs","waitSeconds":51}"#,
            #"{"version":1,"command":"jobs","limit":0}"#,
            #"{"version":1,"command":"job_action","action":"retry"}"#,
            #"{"version":1,"command":"job_action","action":"resume_queue","job":"\#(UUID().uuidString)"}"#,
            #"{"version":1,"command":"job_action","action":"delete","job":"\#(UUID().uuidString)"}"#,
        ]
        for line in lines {
            #expect(error(line)?.code == .badRequest, "\(line)")
        }
    }

    @Test func theFingerprintIsStableAndChangesWithTheParameters() throws {
        let video = AgentVideoRequest(mode: "restyle", prompt: "a", style: UUID())
        let first = try AgentFingerprint.of(video)
        #expect(try AgentFingerprint.of(video) == first)
        #expect(AgentNames.isValidFingerprint(first))
        var other = video
        other.prompt = "b"
        #expect(try AgentFingerprint.of(other) != first)
    }

    @Test func theBudgetCountsReservationsAndNeverOverflows() {
        let budget = AgentCapabilities.Budget(unit: .credits, dailyLimit: 100, spentToday: 30, reservedToday: 50)
        #expect(budget.remaining == 20)
        let huge = AgentCapabilities.Budget(unit: .credits, dailyLimit: 100, spentToday: .max, reservedToday: .max)
        #expect(huge.remaining == 0)
    }
}

@Suite struct InboxSweepTests {
    let inbox = AgentInbox(folder: FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID())"))

    private func upload(_ name: String, age: TimeInterval) throws -> String {
        let folder = try inbox.makeUploadFolder()
        let file = folder.appending(path: name)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: folder.path(percentEncoded: false))
        return file.path(percentEncoded: false)
    }

    @Test func onlyOldFilesNoJobReadsAreSwept() throws {
        let kept = try upload("kept.mov", age: 90_000)
        let old = try upload("old.mov", age: 90_000)
        let fresh = try upload("fresh.mov", age: 60)

        #expect(inbox.sweep(keeping: [kept], before: .now.addingTimeInterval(-86_400)) == 1)

        #expect(FileManager.default.fileExists(atPath: kept))
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: fresh))
    }

    @Test func removeTakesOnlyTheInboxsOwnUploadFolders() throws {
        let staged = try upload("a.png", age: 0)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID()).png")
        try Data("x".utf8).write(to: outside)

        inbox.remove([staged, outside.path(percentEncoded: false), "/etc/hosts"])

        #expect(!FileManager.default.fileExists(atPath: staged))
        #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        #expect(inbox.uploadFolder(of: inbox.folder.appending(path: "x/../../y").path(percentEncoded: false)) == nil)
        try? FileManager.default.removeItem(at: outside)
    }
}
