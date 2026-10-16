import Foundation
import Testing

@testable import JutsuCore

@Test func newJobStartsPreparingAndRoundTripsThroughJSON() throws {
    let spec = JobSpec(
        mode: .motionTransfer,
        source: SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), duration: 10, pixelSize: PixelSize(width: 1920, height: 1080),
            range: 0...10),
        references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))], resolution: .p480)
    var job = Job(spec: spec, providerKind: .apiKey, cost: .usd(3.18, isEstimate: false))
    #expect(job.state == .preparing)
    #expect(job.progress == 0)

    job.remote = RemoteJob(requestID: "r1", correlationID: "c1")
    job.chargedAt = Date(timeIntervalSince1970: 1_000)
    let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
    #expect(decoded == job)
}

@Test func jobStoredBeforeChargedAtDecodesWithoutIt() throws {
    var job = Job(spec: makeSpec(), providerKind: .apiKey, cost: .usd(3.18, isEstimate: false))
    job.chargedAt = Date(timeIntervalSince1970: 1_000)
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    #expect(object.removeValue(forKey: "chargedAt") != nil)

    let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.chargedAt == nil)
    #expect(decoded.id == job.id)
}

@Test func jobStoredBeforeOwnersAndSubmitAttemptsDecodesWithoutThem() throws {
    var job = Job(spec: makeSpec(), providerKind: .account, owner: "user_1", cost: .credits(9, isEstimate: false))
    job.submitAttempt = SubmitAttempt(isIdempotent: false)
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    #expect(object.removeValue(forKey: "owner") != nil)
    #expect(object.removeValue(forKey: "submitAttempt") != nil)

    let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.owner == nil)
    #expect(decoded.submitAttempt == nil)
    #expect(decoded.id == job.id)
    #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)) == job)
}

@Test func jobStoredBeforeBatchesDecodesWithoutOne() throws {
    let job = Job(spec: makeSpec(), providerKind: .apiKey, batchID: UUID(), cost: .usd(3.18, isEstimate: false))
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    #expect(object.removeValue(forKey: "batchID") != nil)

    let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.batchID == nil)
    #expect(decoded.id == job.id)
    #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)).batchID == job.batchID)
}

@Test func jobStoredBeforeParentsDecodesWithoutOne() throws {
    let job = Job(spec: makeSpec(), providerKind: .apiKey, parentID: UUID(), cost: .usd(3.18, isEstimate: false))
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    #expect(object.removeValue(forKey: "parentID") != nil)

    let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.parentID == nil)
    #expect(decoded.id == job.id)
    #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)).parentID == job.parentID)
}

@Test func remoteJobStoredWithoutReturnedURLsDecodesAndTheSubmitStatusIsNeverStored() throws {
    let legacy = Data(#"{"requestID": "r1", "correlationID": "c1"}"#.utf8)
    #expect(try JSONDecoder().decode(RemoteJob.self, from: legacy) == RemoteJob(requestID: "r1", correlationID: "c1"))

    let remote = RemoteJob(
        requestID: "r1", statusURL: URL(string: "https://api.example/requests/r1/status"),
        cancelURL: URL(string: "https://api.example/requests/r1/cancel"), initialStatus: .queued)
    let decoded = try JSONDecoder().decode(RemoteJob.self, from: JSONEncoder().encode(remote))
    var expected = remote
    expected.initialStatus = nil
    #expect(decoded == expected)
}

@Test func priceIsTheServerQuoteOnceThereIsOne() throws {
    var job = Job(spec: makeSpec(), providerKind: .apiKey, cost: .usd(3, isEstimate: false))
    #expect(job.price == .usd(3, isEstimate: false))
    job.serverPrice = .usd(2.5, isEstimate: false)
    #expect(job.price == .usd(2.5, isEstimate: false))
    #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)) == job)
}

@Test func onlyAFinishedRemoteGenerationHasAPaidOutput() {
    var job = Job(spec: makeSpec(), providerKind: .apiKey, cost: .usd(1, isEstimate: false))
    job.remote = RemoteJob(requestID: "r1")
    #expect(!job.hasPaidOutput)
    job.chargedAt = Date(timeIntervalSince1970: 1_000)
    #expect(job.hasPaidOutput)
    job.remote = nil
    #expect(!job.hasPaidOutput)
}

@Test func onlyAJobFailedAtTheDeadlineMayStillFinish() {
    var job = Job(spec: makeSpec(), providerKind: .apiKey, cost: .usd(1, isEstimate: false))
    job.remote = RemoteJob(requestID: "r1")
    job.state = .failed(reason: .deadline)
    #expect(job.mayStillFinish)
    job.state = .failed(reason: .generationFailed)
    #expect(!job.mayStillFinish)
    job.state = .failed(reason: .message("Higgsfield didn't finish this job in time."))
    #expect(!job.mayStillFinish)
}

@Test func jobStoredBeforeStageTimesDecodesWithoutThem() throws {
    var job = Job(
        spec: makeSpec(), providerKind: .apiKey, cost: .usd(3.18, isEstimate: false),
        createdAt: Date(timeIntervalSince1970: 1_000))
    job.submittedAt = Date(timeIntervalSince1970: 1_100)
    job.processingAt = Date(timeIntervalSince1970: 1_160)
    job.chargedAt = Date(timeIntervalSince1970: 1_250)
    job.promotedAt = Date(timeIntervalSince1970: 1_050)
    #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)) == job)
    #expect(job.queueWait == 160)
    #expect(job.processingTime == 90)

    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    for key in ["submittedAt", "processingAt", "promotedAt"] { #expect(object.removeValue(forKey: key) != nil) }
    let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.submittedAt == nil)
    #expect(decoded.processingAt == nil)
    #expect(decoded.promotedAt == nil)
    #expect(decoded.queueWait == nil)
    #expect(decoded.processingTime == nil)
}
