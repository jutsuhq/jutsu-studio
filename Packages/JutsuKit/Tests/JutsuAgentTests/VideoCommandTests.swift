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
}

/// create_video's wait: carried only when asked for, 0 to 50 s, and cut to what is left of the answer deadline.
@Suite struct CreateVideoWaitTests {
    private let video = AgentVideoRequest(mode: "motion_transfer", source: AgentSource(path: "/tmp/a.mov"))

    @Test func aWaitRoundTripsAndIsLeftOutWhenNone() throws {
        let fingerprint = String(repeating: "b", count: 64)
        let waiting = CreateVideoCommand(
            requestID: "r-1", fingerprint: fingerprint, video: video, maxCost: AgentAmount(40, .credits),
            waitSeconds: 30)
        let line = try AgentWire.line(AgentRequest(.createVideo(waiting), id: "1"))
        #expect(try AgentWire.request(from: line.dropLast()).request.get().command == .createVideo(waiting))
        var plain = waiting
        plain.waitSeconds = 0
        let plainLine = try AgentWire.line(AgentRequest(.createVideo(plain), id: "1"))
        #expect(!String(decoding: plainLine, as: UTF8.self).contains("waitSeconds"))
        #expect(String(decoding: line, as: UTF8.self).contains("\"waitSeconds\":30"))
    }

    @Test func aWaitOutsideZeroToFiftyIsRefused() throws {
        let fingerprint = String(repeating: "b", count: 64)
        for seconds in [-1, 51] {
            var command = CreateVideoCommand(
                requestID: "r-1", fingerprint: fingerprint, video: video, maxCost: AgentAmount(40, .credits))
            command.waitSeconds = seconds
            let line = try AgentWire.line(AgentRequest(.createVideo(command), id: "1"))
            guard case .failure(let error) = AgentWire.request(from: line.dropLast()).request else {
                Issue.record("wait_seconds \(seconds) was taken")
                continue
            }
            #expect(error.code == .badRequest)
        }
    }

    @Test func aWaitLeavesTimeToAnswerWithinTheDeadline() {
        #expect(AgentProtocol.waitSeconds(50, after: .zero) == 50)
        #expect(AgentProtocol.waitSeconds(50, after: .seconds(10)) == 40)
        #expect(AgentProtocol.waitSeconds(20, after: .seconds(10)) == 20)
        #expect(AgentProtocol.waitSeconds(50, after: .seconds(60)) == 0)
        let elapsed = Duration.seconds(12)
        #expect(
            Duration.seconds(AgentProtocol.waitSeconds(50, after: elapsed)) + elapsed < AgentProtocol.answerDeadline)
    }
}

/// What a quote says about a job before upload: an estimate doesn't hold it, and says how its price is checked.
@Suite struct QuoteAdviceTests {
    @Test func anEstimateWithinTheBudgetIsNoBlockerAndSaysHowItRuns() throws {
        #expect(AgentQuote.blocker(price: 24, remaining: 500, paysUnlimited: false, unlimitedAllowed: false) == nil)
        let note = try #require(AgentQuote.priceNote(isEstimate: true, hasPrice: true, paysUnlimited: false))
        #expect(note.contains("runs on its own") && note.contains("max_cost"))
        #expect(AgentQuote.priceNote(isEstimate: false, hasPrice: true, paysUnlimited: false) == nil)
        #expect(AgentQuote.priceNote(isEstimate: true, hasPrice: false, paysUnlimited: false) == nil)
        #expect(AgentQuote.priceNote(isEstimate: true, hasPrice: true, paysUnlimited: true) == nil)
    }

    @Test func anUnknownPriceOrOneOverTheBudgetStillWaitsForThePerson() {
        let unknown = AgentQuote.blocker(price: nil, remaining: 500, paysUnlimited: false, unlimitedAllowed: false)
        #expect(unknown?.contains("isn't known") == true)
        let over = AgentQuote.blocker(price: 501, remaining: 500, paysUnlimited: false, unlimitedAllowed: false)
        #expect(over?.contains("more than is left") == true)
        let unlimited = AgentQuote.blocker(price: 0, remaining: 0, paysUnlimited: true, unlimitedAllowed: false)
        #expect(unlimited?.contains("unlimited") == true)
        #expect(AgentQuote.blocker(price: 0, remaining: 0, paysUnlimited: true, unlimitedAllowed: true) == nil)
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
