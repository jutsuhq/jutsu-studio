import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// library_get over catalog entries as the store holds them.
@Suite struct AgentLibraryDetailTests {
    let character = CatalogFixture.image(prompt: "A knight", minutesAgo: 20)

    /// A motion transfer of two references, the first of them the Library's knight, its prompt longer than a row's.
    var swap: Material {
        let item = LibraryFixture.item(
            mode: .motionTransfer, isDraft: false, prompt: String(repeating: "dance ", count: 60), references: 2)
        var version = MaterialVersion(
            id: item.job.id, createdAt: LibraryFixture.now, fileURL: item.job.outputFile,
            generation: MaterialGeneration(prompt: item.spec.prompt, model: item.spec.model.rawValue),
            inputs: [MaterialInput(source: character.reference, role: .reference, position: 0)], video: item.job)
        version.culling = .rejected
        return Material(id: item.job.id, kind: .video, createdAt: item.job.createdAt, version: version)
    }

    @Test func aVideoInFullHasTheWholePromptItsInputsInOrderAndItsSettings() throws {
        let swap = swap
        let (details, missing) = AgentLibraryDetail.of([swap.id], in: [swap, character])
        #expect(missing.isEmpty)
        let detail = try #require(details.first)
        // Rejected, yet named by ID, so it is there; the prompt isn't cut.
        #expect(detail.hit.culling == .rejected)
        #expect(detail.hit.jobID == swap.id)
        #expect(detail.hit.prompt == swap.current.video?.spec.prompt)
        #expect(!detail.hit.isPromptTruncated)
        #expect(detail.inputs.map(\.role) == [.source, .reference, .reference])
        #expect(detail.inputs.map(\.position) == [nil, 1, 2])
        #expect(detail.inputs[0].range == 4...10)
        #expect(detail.inputs[0].file?.lastPathComponent == "rooftop.mov")
        #expect(detail.inputs[1].item == character.id)
        #expect(detail.inputs[2].item == nil)
        #expect(detail.settings.resolution == "480p")
        #expect(detail.settings.isDraft == false)
        #expect(detail.settings.audio == "original")
        #expect(detail.settings.operation == nil)
    }

    @Test func anImageListsWhatItEditedAndItsRequest() throws {
        let request = ImageRequest(model: "soul", prompt: "A knight, side view", aspectRatio: "3:4", count: 4)
        var version = MaterialVersion(
            fileURL: URL(fileURLWithPath: "/tmp/side.png"),
            generation: MaterialGeneration(
                prompt: request.prompt, model: "soul", parameters: try JSONEncoder().encode(request)),
            inputs: [MaterialInput(source: character.reference, role: .reference, position: 0)])
        version.aspectRatio = "3:4"
        let side = Material(kind: .image, version: version)
        let detail = try #require(AgentLibraryDetail.of([side.id], in: [side, character]).details.first)
        #expect(detail.inputs.map(\.item) == [character.id])
        #expect(detail.inputs.first?.position == 1)
        #expect(detail.inputs.first?.file == character.current.fileURL)
        #expect(detail.settings.count == 4)
        #expect(detail.settings.aspectRatio == "3:4")
    }

    /// A version made from an earlier one of the same item names it, so an agent can compare or go back.
    @Test func aNewVersionNamesTheOneItWasMadeFrom() throws {
        var image = Material(kind: .image, version: MaterialVersion(fileURL: URL(fileURLWithPath: "/tmp/a.png")))
        let original = image.reference
        try image.addVersion(
            MaterialVersion(
                fileURL: URL(fileURLWithPath: "/tmp/a 4x.png"), inputs: [MaterialInput(source: original, role: .parent)]
            ))

        let detail = try #require(AgentLibraryDetail.of([image.id], in: [image]).details.first)

        #expect(detail.madeFrom?.reference == original)
        #expect(detail.madeFrom?.version == 1)
        #expect(detail.madeFrom?.file?.lastPathComponent == "a.png")
        #expect(detail.hit.version == 2)
        #expect(AgentLibraryDetail.of([character.id], in: [character]).details.first?.madeFrom == nil)
    }

    /// A video of the account's Higgsfield history: no file on this Mac, only its link and what the history says.
    var historyVideo: Material {
        let item = LibraryFixture.item(mode: .motionTransfer, isDraft: false, prompt: "a long history prompt")
        var job = item.job
        job.outputFile = nil
        let version = MaterialVersion(
            id: job.id, createdAt: LibraryFixture.now, remoteURL: URL(string: "https://cdn.example.com/clip.mp4"),
            generation: MaterialGeneration(prompt: job.spec.prompt, model: job.spec.model.rawValue), video: job)
        var material = Material(
            id: job.id, kind: .video, origin: .higgsfield, createdAt: job.createdAt, version: version)
        material.remote = MaterialRemote(provider: .account, owner: nil, id: "gen-2")
        return material
    }

    /// One only on Higgsfield is answered from the history, with no file; an unknown ID fails alone.
    @Test func aHistoryResultIsInFullWithoutAFileAndAnUnknownIDIsMissingAlone() throws {
        let history = historyVideo
        let unknown = UUID()
        let (details, missing) = AgentLibraryDetail.of([character.id, unknown, history.id], in: [character, history])
        #expect(details.map(\.hit.id) == [character.id, history.id])
        #expect(missing == [unknown])
        let detail = try #require(details.last)
        #expect(detail.hit.isOnHiggsfield && detail.hit.file == nil)
        #expect(detail.hit.jobID == nil)
        #expect(detail.hit.prompt == "a long history prompt")
        #expect(detail.hit.mode == "motion_transfer")
        #expect(detail.settings.resolution == "480p")
    }
}
