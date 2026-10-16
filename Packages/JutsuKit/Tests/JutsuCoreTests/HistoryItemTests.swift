import Foundation
import Testing

@testable import JutsuCore

func makeHistoryItem(
    id: String = "job-1", mode: Mode = .objectSwap, model: VideoModel = .genjutsu, isLiked: Bool = false,
    createdAt: Date = Date(timeIntervalSince1970: 1_791_032_606), prompt: String = "swap the cup"
) -> HistoryItem {
    let cdn = "https://cdn.example"
    return HistoryItem(
        id: id, mode: mode, model: model, createdAt: createdAt, isLiked: isLiked,
        outputURL: URL(string: "\(cdn)/\(id).mp4") ?? URL(fileURLWithPath: "/"), duration: 8,
        pixelSize: PixelSize(width: 1080, height: 1920), resolution: .p720, prompt: prompt,
        inputs: RemoteInputs(
            video: RemoteAsset(url: URL(string: "\(cdn)/in.mp4") ?? URL(fileURLWithPath: "/"), id: "media-v"),
            images: [RemoteAsset(url: URL(string: "\(cdn)/a.png") ?? URL(fileURLWithPath: "/"), id: "media-a")]))
}

@Test func importedHistoryItemIsAFinishedAccountJobWithItsRemoteID() {
    let item = makeHistoryItem()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let job = Job(importing: item, owner: "user_1", importedAt: now)

    #expect(job.id == item.jobID)
    #expect(job.state == .done && job.progress == 1)
    #expect(job.providerKind == .account && job.owner == "user_1")
    #expect(job.remote == RemoteJob(requestID: "job-1"))
    #expect(job.inputs == item.inputs)
    #expect(job.importedAt == now)
    #expect(job.createdAt == item.createdAt && job.finishedAt == item.createdAt)
    #expect(job.outputFile == nil)
    #expect(job.price == .credits(0, isEstimate: true))
    #expect(job.spec.remoteInputs == item.inputs)
    #expect(job.spec.source?.fileURL == item.inputs.video?.url)
    #expect(job.spec.source?.range == 0...8)
    #expect(job.spec.source?.pixelSize == PixelSize(width: 1080, height: 1920))
    #expect(job.spec.references.map(\.fileURL) == item.inputs.images.map(\.url))
    #expect(job.spec.mode == .objectSwap && job.spec.resolution == .p720 && job.spec.prompt == "swap the cup")
}

@Test func historySpecUsesTheProbedSourceWhole() {
    let spec = makeHistoryItem().spec(sourceDuration: 14.2, sourceSize: PixelSize(width: 1920, height: 1080))
    #expect(spec.source?.duration == 14.2)
    #expect(spec.source?.range == 0...14.2)
    #expect(spec.source?.pixelSize == PixelSize(width: 1920, height: 1080))
}

@Test func jobStoredBeforeImportsAndReusedInputsDecodesWithoutThem() throws {
    var job = Job(importing: makeHistoryItem(), owner: "user_1", importedAt: Date(timeIntervalSince1970: 5))
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    #expect(object.removeValue(forKey: "importedAt") != nil)
    var spec = try #require(object["spec"] as? [String: Any])
    #expect(spec.removeValue(forKey: "remoteInputs") != nil)
    object["spec"] = spec

    let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.importedAt == nil)
    #expect(decoded.spec.remoteInputs == nil)
    #expect(decoded.id == job.id)
    job.outputFile = URL(fileURLWithPath: "/tmp/out.mp4")
    #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)) == job)
}
