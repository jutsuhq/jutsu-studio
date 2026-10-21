import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// library_search and library_mark over catalog entries as the store holds them.
@Suite struct AgentLibraryTests {
    let fox = CatalogFixture.video(prompt: "A fox runs", minutesAgo: 1)
    let kept = CatalogFixture.video(prompt: "A kept owl", minutesAgo: 2, culling: .kept)
    let rejected = CatalogFixture.video(prompt: "A rejected fox", minutesAgo: 3, culling: .rejected)
    let image = CatalogFixture.image(prompt: "A fox portrait", minutesAgo: 4)
    var materials: [Material] { [fox, kept, rejected, image] }

    func ids(_ query: AgentLibraryQuery) -> [UUID] {
        AgentLibrarySearch.page(materials, query).hits.map(\.id)
    }

    @Test func rejectedResultsStayOutUnlessAskedFor() {
        #expect(ids(AgentLibraryQuery()) == [fox.id, kept.id, image.id])
        #expect(ids(AgentLibraryQuery(includeRejected: true)) == [fox.id, kept.id, rejected.id, image.id])
        #expect(ids(AgentLibraryQuery(verdict: .rejected)) == [rejected.id])
        #expect(ids(AgentLibraryQuery(verdict: .kept)) == [kept.id])
    }

    @Test func theFiltersAreTheLibrarysAndTheirOwn() {
        #expect(ids(AgentLibraryQuery(text: "fox")) == [fox.id, image.id])
        #expect(ids(AgentLibraryQuery(kind: .image)) == [image.id])
        #expect(ids(AgentLibraryQuery(kind: .video)) == [fox.id, kept.id])
        // A mode lists videos only; an image model's name, images only.
        #expect(ids(AgentLibraryQuery(mode: .restyle)) == [fox.id, kept.id])
        #expect(ids(AgentLibraryQuery(model: "soul")) == [image.id])
        #expect(ids(AgentLibraryQuery(starred: true)).isEmpty)
        #expect(ids(AgentLibraryQuery(starred: false)) == [fox.id, kept.id, image.id])
        let cutoff = CatalogFixture.now.addingTimeInterval(-150)
        #expect(ids(AgentLibraryQuery(from: cutoff)).contains(fox.id))
        #expect(!ids(AgentLibraryQuery(to: cutoff)).contains(fox.id))
    }

    /// An image of the account's Higgsfield history: no file on this Mac, only its link.
    var cloud: Material {
        var material = Material(
            kind: .image, createdAt: CatalogFixture.now.addingTimeInterval(-30),
            version: MaterialVersion(
                remoteURL: URL(string: "https://cdn.example.com/cloud.png"),
                generation: MaterialGeneration(prompt: "A cloud fox", model: "soul")))
        material.remote = MaterialRemote(provider: .account, owner: nil, id: "gen-1")
        return material
    }

    @Test func theHiggsfieldHistoryIsListedOnlyWhenAskedFor() throws {
        let cloud = cloud
        let all = materials + [cloud]
        let local = AgentLibrarySearch.page(all, AgentLibraryQuery(text: "fox")).hits
        #expect(local.map(\.id) == [fox.id, image.id])
        let hits = AgentLibrarySearch.page(all, AgentLibraryQuery(text: "fox", includeHiggsfield: true)).hits
        #expect(hits.map(\.id) == [cloud.id, fox.id, image.id])
        let first = try #require(hits.first)
        #expect(first.isOnHiggsfield && first.file == nil && first.model == "soul")
        #expect(hits.dropFirst().allSatisfy { !$0.isOnHiggsfield && $0.file != nil })
        // A mode lists videos only, the history's images too.
        let videos = AgentLibrarySearch.page(all, AgentLibraryQuery(mode: .restyle, includeHiggsfield: true)).hits
        #expect(videos.allSatisfy { $0.isVideo })
    }

    @Test func aDownloadIsPlannedFromWhatEachIDIs() {
        let cloud = cloud
        let plan = AgentLibraryDownload.plan([cloud.id, image.id, UUID()], in: materials + [cloud])
        guard case .image(let remote) = plan[0] else {
            Issue.record("not the history image: \(plan[0])")
            return
        }
        #expect(remote.jobID == cloud.id && remote.id == "gen-1")
        #expect(plan[1] == image.current.fileURL.map(AgentLibraryDownload.local))
        #expect(plan[2] == .missing)
    }

    @Test func pagesFollowTheCursorWithoutRepeatsOrGaps() {
        var seen: [UUID] = []
        var cursor: String?
        repeat {
            let page = AgentLibrarySearch.page(
                materials, AgentLibraryQuery(includeRejected: true, limit: 1, cursor: cursor))
            seen += page.hits.map(\.id)
            cursor = page.next
        } while cursor != nil
        #expect(seen == [fox.id, kept.id, rejected.id, image.id])
    }

    @Test func promptsAreCutAndSaySo() throws {
        let long = CatalogFixture.image(prompt: String(repeating: "a", count: 300))
        let hit = try #require(AgentLibrarySearch.page([long], AgentLibraryQuery()).hits.first)
        #expect(hit.prompt.count == AgentLibrarySearch.promptLength)
        #expect(hit.isPromptTruncated)
        let video = try #require(AgentLibrarySearch.page([fox], AgentLibraryQuery()).hits.first)
        #expect(!video.isPromptTruncated)
        #expect(video.mode == "restyle")
        #expect(video.version == 1 && video.versionCount == 1)
        #expect(video.file?.lastPathComponent == "out.mp4")
    }

    @Test func markingAgainChangesNothing() {
        let first = AgentLibraryMarks(ids: [fox.id, kept.id], verdict: .keep, star: nil, materials: materials)
        #expect(first.culling.count == 1)
        #expect(first.results.map(\.culling) == [.kept, .kept])
        var marked = materials
        marked[0].current.culling = .kept
        let again = AgentLibraryMarks(ids: [fox.id, kept.id], verdict: .keep, star: nil, materials: marked)
        #expect(again.changes == 0)
    }

    @Test func theStarIsApartFromTheVerdict() {
        let marks = AgentLibraryMarks(ids: [fox.id, image.id], verdict: nil, star: true, materials: materials)
        #expect(marks.culling.isEmpty)
        #expect(marks.videos.map(\.id) == [fox.id])
        #expect(marks.images == [image.id])
        #expect(marks.results.map(\.isStarred) == [true, true])
        #expect(marks.results.map(\.culling) == [.unreviewed, .unreviewed])
    }

    @Test func anUnknownIDChangesNothing() {
        let marks = AgentLibraryMarks(ids: [fox.id, UUID()], verdict: .reject, star: true, materials: materials)
        #expect(marks.missing.count == 1)
        #expect(marks.changes == 0)
    }
}

/// enhance: the Enhance sheet's options from an agent's fields, and the operations it refuses.
@Suite struct AgentEnhanceOrderTests {
    let video = LibraryFixture.item()

    @Test func leftOutOptionsAreTheSheetsDefaults() throws {
        let upscale = try AgentEnhanceOrder(kind: .upscale).action(voices: nil).get()
        #expect(upscale == .upscale(UpscaleOptions(target: .p1080, frameRate: .fps24, engine: .standard)))
        #expect(
            try AgentEnhanceOrder(kind: .reframe, aspectRatio: "9:16").action(voices: nil).get() == .reframe(.portrait))
        #expect(try AgentEnhanceOrder(kind: .dub, language: "fra").action(voices: nil).get() == .dub(.french))
    }

    @Test func topazIsRefusedForItsPriceComesAfterTheRun() {
        guard case .failure(let refusal) = AgentEnhanceOrder(kind: .upscale, engine: "topaz").action(voices: nil) else {
            Issue.record("Topaz was taken")
            return
        }
        #expect(refusal.kind == .pricedAfterRun)
    }

    @Test func aVoiceMustBeTheAccountsOwn() throws {
        let voice = VoiceChoice(id: "v1", type: "preset", name: "Ava")
        #expect(
            try AgentEnhanceOrder(kind: .changeVoice, voice: "v1").action(voices: [voice]).get() == .changeVoice(voice))
        guard case .failure(let refusal) = AgentEnhanceOrder(kind: .changeVoice, voice: "v2").action(voices: [voice])
        else {
            Issue.record("an unknown voice was taken")
            return
        }
        #expect(refusal.kind == .invalid)
    }

    @Test func theSheetsOwnAvailabilityGuardsIt() {
        let hidden = AgentEnhanceOrder.refusal(.removeBackground, on: video, availability: .hidden, duration: 5)
        #expect(hidden?.kind == .unavailable)
        let waiting = AgentEnhanceOrder.refusal(
            .removeBackground, on: video, availability: .disabled(reason: "Waiting"), duration: 5)
        #expect(waiting?.message == "Waiting")
        #expect(AgentEnhanceOrder.refusal(.reframe(.square), on: video, availability: .available, duration: 61) != nil)
        #expect(AgentEnhanceOrder.refusal(.reframe(.square), on: video, availability: .available, duration: 10) == nil)
    }
}

/// delivery_set and export never write over a file.
@Suite struct AgentExportsTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "agent-exports-\(UUID().uuidString)")

    func touch(_ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: name))
    }

    @Test func editingTakesGetNamesNoFileHas() throws {
        let item = LibraryFixture.item()
        let first = AgentExports.editingNames(for: [item], preset: .premiere, existing: []).first
        try touch(try #require(first).video.uppercased())
        let names = AgentExports.editingNames(
            for: [item, item], preset: .premiere, existing: AgentExports.existingNames(in: folder))
        #expect(names.count == 2)
        #expect(!names.contains { $0.video.lowercased() == first?.video.lowercased() })
        #expect(Set(names.map(\.video)).count == 2)
    }

    @Test func aDeliveryNeverReplacesEvenItsOwnFiles() throws {
        let material = CatalogFixture.image()
        var set = DeliverySet(name: "Client", items: DeliverySet.items(from: [material]))
        let planned = try #require(AgentExports.deliveryTasks(for: set, existing: []).first)
        // Exported once, then the output changed: the sheet would write the same name again.
        set.record([planned.result(.done)], in: DeliverySet.Folder(url: folder), at: Date())
        var outputs = set.outputs
        outputs[0].preset = .image(ImageExportPreset(format: .jpeg, longEdge: 1024))
        set.outputs = outputs
        try touch(planned.fileName)

        let again = try #require(
            AgentExports.deliveryTasks(for: set, existing: AgentExports.existingNames(in: folder)).first)

        #expect(!again.replacesExisting)
        #expect(again.fileName != planned.fileName)
    }

    @Test func onlyFoldersThePersonExportedToAreTaken() {
        var set = DeliverySet(name: "Client", items: [])
        set.record([], in: DeliverySet.Folder(url: folder), at: Date())
        #expect(AgentExports.knownFolder(folder.path(percentEncoded: false) + "/", in: [set]) == nil)
        let material = CatalogFixture.image()
        var exported = DeliverySet(name: "Client", items: DeliverySet.items(from: [material]))
        let task = AgentExports.deliveryTasks(for: exported, existing: []).first
        exported.record(task.map { [$0.result(.done)] } ?? [], in: DeliverySet.Folder(url: folder), at: Date())
        #expect(AgentExports.knownFolder(folder.path(percentEncoded: false) + "/", in: [exported]) != nil)
        #expect(AgentExports.knownFolder("/tmp/elsewhere", in: [exported]) == nil)
        #expect(AgentExports.folders(of: [exported, exported]).count == 1)
    }
}

/// Stage 2's jobs list, paged, and a retry whose files are gone.
@Suite struct AgentJobPagingTests {
    @Test func videoJobsAndImageRequestsPageTogetherNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = (0..<5).map { (now.addingTimeInterval(Double(-$0)), UUID()) }
        var seen: [UUID] = []
        var cursor: String?
        repeat {
            let page = AgentJobPage.page(entries.shuffled(), limit: 2, after: cursor)
            seen += page.ids
            cursor = page.next
        } while cursor != nil
        #expect(seen == entries.map(\.1))
    }

    @Test func aRetryWhoseInputsWereSweptIsRefused() {
        var job = LibraryFixture.item().job
        job.state = .failed(reason: .inputUnavailable)
        job.remote = nil
        job.agent = AgentOrigin(client: nil, requestID: "r", maxCost: AgentMoney(10, .usdCents))
        #expect(AgentJobRules.retryRefusal(job) { _ in true } == nil)
        #expect(AgentJobRules.retryRefusal(job) { _ in false }?.contains("new request_id") == true)
    }
}

/// create_video's style is checked against the cached catalog before anything is queued.
@Suite struct AgentStyleTests {
    @Test func onlyACachedStyleIsTaken() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "styles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let style = StylePreset(
            id: UUID(), name: "Claymation", previewURL: URL(string: "https://cdn.example.com/c.png")!)
        try JSONEncoder().encode([style]).write(to: folder.appending(path: PresetCatalog.cacheFileName))

        #expect(PresetCatalog.agentStyleRefusal(style.id, in: folder) == nil)
        #expect(PresetCatalog.agentStyleRefusal(UUID(), in: folder)?.contains("styles true") == true)
        #expect(PresetCatalog.agentStyleRefusal(style.id, in: folder.appending(path: "none")) != nil)
    }
}
