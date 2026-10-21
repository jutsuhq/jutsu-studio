import Foundation
import HiggsfieldProviders
import JobEngine
import JutsuAgent
import JutsuCore
import MediaKit
import Persistence
import Presentation
import SwiftData
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// library_search, library_mark, enhance, delivery_set and export: the Library's own code paths (its filters, culling,
// star, Enhance jobs, delivery sets and Export for Editing), never anything that deletes or trashes.
extension AgentService {
    // MARK: library_search

    func librarySearch(_ fields: LibrarySearchCommand) async throws(AgentError) -> AgentLibraryPage {
        let query = AgentLibraryQuery(
            text: fields.query ?? "", kind: Self.kind(fields.kind), starred: fields.starred,
            verdict: fields.verdict.map(Self.culling), includeRejected: fields.includeRejected ?? false,
            model: fields.model, mode: fields.mode.flatMap(AgentVideoOrder.mode(named:)), from: fields.from,
            to: fields.to, limit: fields.limit ?? LibrarySearchCommand.defaultLimit, cursor: fields.cursor)
        let (hits, next) = AgentLibrarySearch.page(try await materials(), query)
        return AgentLibraryPage(items: hits.map(Self.item), nextCursor: next)
    }

    private static func item(_ hit: AgentLibraryHit) -> AgentLibraryItem {
        AgentLibraryItem(
            id: hit.id, kind: hit.isVideo ? .video : .image, file: hit.file.path(percentEncoded: false),
            model: hit.model, mode: hit.mode, aspectRatio: hit.aspectRatio, duration: hit.duration,
            price: hit.price.flatMap(AgentMoney.init).map { AgentAmount($0.amount, unit(of: $0.unit)) },
            verdict: verdict(hit.culling), starred: hit.isStarred, createdAt: hit.createdAt, prompt: hit.prompt,
            promptTruncated: hit.isPromptTruncated, versionID: hit.versionID, version: hit.version,
            versionCount: hit.versionCount, jobID: hit.jobID)
    }

    // MARK: library_mark

    func libraryMark(_ fields: LibraryMarkCommand) async throws(AgentError) -> AgentMarked {
        let action = fields.verdict.map { verdict -> CullingAction in
            switch verdict {
            case .keep: .keep
            case .reject: .reject
            case .clear: .clear
            }
        }
        let marks = AgentLibraryMarks(
            ids: fields.ids, verdict: action, star: fields.star, materials: try await materials())
        if let missing = marks.missing.first {
            throw AgentError(
                .notFound,
                message: "There's no Library item \(missing.uuidString) with a file on this Mac; nothing "
                    + "was changed.", retryable: false, next: "Call library_search for the item IDs.")
        }
        do {
            if !marks.culling.isEmpty { try await environment.store.setCulling(marks.culling) }
            if let star = fields.star, !marks.videos.isEmpty {
                let ids = Set(marks.videos.map(\.id))
                let records = try environment.modelContainer.mainContext.fetch(
                    FetchDescriptor<MaterialRecord>(predicate: #Predicate { ids.contains($0.id) }))
                try await environment.setStarred(star, marks.videos, records: records)
            }
            if let star = fields.star, !marks.images.isEmpty {
                try await environment.imageLibrary.setStarred(star, for: marks.images)
            }
        } catch {
            logger.error("Can't mark Library items: \(String(describing: error), privacy: .private)")
            throw AgentError(
                .failed, message: "The marks couldn't all be saved: \(error.localizedDescription)", retryable: true,
                next: "Send the same library_mark again; what was saved stays as it is.")
        }
        return AgentMarked(
            items: marks.results.map {
                AgentMarked.Item(id: $0.id, verdict: Self.verdict($0.culling), starred: $0.isStarred)
            },
            changed: marks.changes)
    }

    // MARK: enhance

    func enhance(_ fields: EnhanceCommand, client: String?) async throws(AgentError) -> AgentCreated {
        if let running = creating[fields.requestID] {
            guard running.fingerprint == fields.fingerprint else { throw .requestConflict }
            return try await running.task.value.get()
        }
        switch try lookup(fields.requestID, fingerprint: fields.fingerprint) {
        case .conflict:
            throw .requestConflict
        case .known(let ids):
            let jobs = try await knownJobs(ids)
            guard jobs.isEmpty else {
                return AgentCreated(requestID: fields.requestID, known: true, jobs: jobs.map(Self.agentJob))
            }
            try? environment.agentRequests.remove(fields.requestID)
            throw AgentError(
                .failed, message: "The request was recorded but its job was never queued.", retryable: true,
                next: "Send the same enhance again.")
        case .new:
            break
        }
        let task = Task { [weak self] () -> Result<AgentCreated, AgentError> in
            guard let self else { return .failure(.agentsOff) }
            do throws(AgentError) {
                return .success(try await self.queueEnhancement(fields, client: client))
            } catch {
                return .failure(error)
            }
        }
        creating[fields.requestID] = (fields.fingerprint, task)
        defer { creating[fields.requestID] = nil }
        return try await task.value.get()
    }

    /// Builds the job as the Enhance sheet would, records the request with its ID, then queues it with the agent's
    /// origin: the engine's spending guard checks it before its submit, and holds one whose price isn't known.
    private func queueEnhancement(_ fields: EnhanceCommand, client: String?) async throws(AgentError) -> AgentCreated {
        guard let kind = environment.connection.state.kind else { throw Self.notConnected }
        try Self.checkUnit(of: fields.maxCost, on: kind)
        let materials = try await materials()
        guard let material = materials.first(where: { $0.id == fields.item }),
            case .video(let item)? = MaterialLibrary.row(material), item.historyItem == nil, item.outputFile != nil
        else {
            throw AgentError(
                .notFound, message: "There's no video \(fields.item.uuidString) with a file on this Mac.",
                retryable: false, next: "Call library_search with kind video for the item IDs.")
        }
        let spec = try await enhancementSpec(fields, on: item, connection: kind)
        let jobID = UUID()
        try recordRequest(fields.requestID, fingerprint: fields.fingerprint, jobIDs: [jobID])
        let origin = AgentOrigin(
            client: client, requestID: fields.requestID,
            maxCost: AgentMoney(fields.maxCost.amount, Self.unit(of: fields.maxCost.unit)))
        do {
            let job = try await environment.engine.enqueue(spec, parentID: item.id, id: jobID, agent: origin)
            logger.info(
                "Agent \(client ?? "unnamed", privacy: .private) queued \(fields.operation.rawValue, privacy: .public)")
            return AgentCreated(requestID: fields.requestID, known: false, jobs: [Self.agentJob(job)])
        } catch {
            try? environment.agentRequests.remove(fields.requestID)
            throw Self.agentError(enqueueing: error)
        }
    }

    /// The job the Enhance sheet would queue for these fields on `item`, refused as the sheet would refuse it.
    private func enhancementSpec(
        _ fields: EnhanceCommand, on item: LibraryItemModel, connection kind: ProviderKind
    ) async throws(AgentError) -> JobSpec {
        let order = AgentEnhanceOrder(
            kind: Self.kind(of: fields.operation), target: fields.target, frameRate: fields.frameRate,
            engine: fields.engine, aspectRatio: fields.aspectRatio, language: fields.language, voice: fields.voice)
        let voices = fields.operation == .changeVoice ? await environment.voices()?.map(\.choice) : nil
        let action: PostAction
        switch order.action(voices: voices) {
        case .success(let chosen): action = chosen
        case .failure(let refusal): throw Self.error(refusal)
        }
        let availability = EnhanceAvailability.of(
            item, connection: kind, offered: HiggsfieldMCPProvider.offersPostOperations)
        if let refusal = AgentEnhanceOrder.refusal(
            action, on: item, availability: availability, duration: item.job.outputDuration)
        {
            throw Self.error(refusal)
        }
        if case .reframe(let aspect) = action, let size = item.job.outputPixelSize,
            ReframeCanvas(source: size, aspect: aspect)?.isUnchanged == true
        {
            throw .invalidRequest("The video is \(aspect.rawValue) already, so Reframe has nothing to fill in.")
        }
        guard let spec = item.job.operationSpec(action, owner: environment.provider?.owner) else {
            throw .invalidRequest("The video's file isn't on this Mac.")
        }
        return spec
    }

    private static func error(_ refusal: AgentEnhanceOrder.Refusal) -> AgentError {
        switch refusal.kind {
        case .invalid:
            .badRequest("enhance: \(refusal.message)")
        case .pricedAfterRun:
            AgentError(
                .pricedAfterRun, message: refusal.message, retryable: false,
                next: "Use the standard engine, or ask the person to run a Topaz upscale themselves.")
        case .unavailable:
            AgentError(.notApplicable, message: refusal.message, retryable: true, next: "Ask the person to check.")
        }
    }

    // MARK: delivery_set

    func deliverySet(_ fields: DeliverySetCommand) async throws(AgentError) -> AgentDelivery {
        let store = environment.store
        switch fields.action {
        case .create:
            let materials = try await materials()
            let local = Set(materials.filter { MaterialLibrary.row($0)?.isLocal == true }.map(\.id))
            if let missing = fields.items.first(where: { !local.contains($0) }) {
                throw AgentError(
                    .notFound, message: "There's no Library item \(missing.uuidString) with a file on this Mac.",
                    retryable: false, next: "Call library_search for the item IDs.")
            }
            let byID = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let set = DeliverySet(
                name: fields.name ?? DeliveryContent.defaultName(at: .now),
                items: DeliverySet.items(from: fields.items.compactMap { byID[$0] }))
            do {
                try await store.saveDeliverySet(set)
            } catch {
                throw AgentError(.failed, message: error.localizedDescription, retryable: true)
            }
            return AgentDelivery(action: .create, set: Self.agentSet(set))
        case .list:
            let sets = try await deliverySets()
            return AgentDelivery(
                action: .list, sets: sets.sorted { $0.createdAt > $1.createdAt }.map(Self.agentSet),
                folders: AgentExports.folders(of: sets).map { $0.url.path(percentEncoded: false) })
        case .export:
            return try await exportDelivery(fields)
        }
    }

    /// Writes what is still to write of the set, never over a file, into a folder the person exported a set to, or
    /// the output folder's Exports folder, and records it on the set as the sheet does.
    private func exportDelivery(_ fields: DeliverySetCommand) async throws(AgentError) -> AgentDelivery {
        let sets = try await deliverySets()
        guard let set = sets.first(where: { $0.id == fields.set }) else {
            throw AgentError(
                .notFound, message: "There's no delivery set \(fields.set?.uuidString ?? "").", retryable: false,
                next: "Call delivery_set with action list for the set IDs.")
        }
        let folder = try deliveryFolder(fields.folder, in: sets)
        let access = SecurityScopedAccess(url: folder.url, bookmark: folder.bookmark)
        defer { withExtendedLifetime(access) {} }
        let directory = access.url
        try Self.makeFolder(directory)
        let versions = Self.versions(of: set, in: try await materials())
        let tasks = AgentExports.deliveryTasks(for: set, existing: AgentExports.existingNames(in: directory))
        let results = await DeliveryRun.run(tasks) { task in
            try await DeliveryExportModel.export(task, version: versions[task.item.reference], into: directory)
        }
        var recorded = set
        if !results.isEmpty {
            let date = Date()
            recorded.record(results, in: DeliverySet.Folder(url: directory, bookmark: folder.bookmark), at: date)
            DeliveryExportModel.writeManifest(of: recorded, at: date, into: directory, replacing: false)
            do {
                try await environment.store.saveDeliverySet(recorded)
            } catch {
                logger.error("Can't record a delivery export: \(String(describing: error), privacy: .private)")
            }
        }
        let files = zip(tasks, results).map { task, result in
            AgentExportFile(
                item: task.item.reference.materialID, status: Self.status(result.status),
                file: result.status == .done
                    ? directory.appending(path: task.fileName).path(percentEncoded: false) : nil,
                message: result.message, output: DeliveryContent.summary(of: task.output))
        }
        return AgentDelivery(
            action: .export, set: Self.agentSet(recorded), folder: directory.path(percentEncoded: false), files: files)
    }

    /// A folder the person exported a set to, else the output folder's Exports.
    private func deliveryFolder(_ path: String?, in sets: [DeliverySet]) throws(AgentError) -> DeliverySet.Folder {
        guard let path else { return DeliverySet.Folder(url: environment.outputFolder.url(of: .exports)) }
        guard let known = AgentExports.knownFolder(path, in: sets) else {
            throw AgentError(
                .fileRefused, message: "\(path) isn't a folder the person exported a delivery set to.",
                retryable: false,
                next: "Leave out folder for the output folder's Exports, or pick one of list's folders.")
        }
        return known
    }

    /// The versions the set's items name, as the catalog holds them.
    private static func versions(of set: DeliverySet, in materials: [Material]) -> [MaterialReference: MaterialVersion]
    {
        var versions: [MaterialReference: MaterialVersion] = [:]
        for item in set.items {
            versions[item.reference] = materials.first { $0.id == item.reference.materialID }?.versions
                .first { $0.id == item.reference.versionID }
        }
        return versions
    }

    private static func makeFolder(_ folder: URL) throws(AgentError) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AgentError(.failed, message: error.localizedDescription, retryable: true)
        }
    }

    private static func agentSet(_ set: DeliverySet) -> AgentDeliverySet {
        AgentDeliverySet(
            id: set.id, name: set.name, createdAt: set.createdAt, itemCount: set.items.count, frozen: set.isFrozen,
            exportedAt: set.exportedAt, folder: set.folder?.url.path(percentEncoded: false),
            outputs: set.outputs.map(DeliveryContent.summary(of:)))
    }

    private static func status(_ status: DeliveryResult.Status) -> AgentExportFile.Status {
        switch status {
        case .done: .done
        case .failed: .failed
        case .skipped: .skipped
        }
    }

    // MARK: export

    func exportForEditing(_ fields: ExportCommand) async throws(AgentError) -> AgentExported {
        let preset = Self.preset(fields.preset)
        let folder = environment.outputFolder.url(of: .exports)
        try Self.makeFolder(folder)
        let byID = Dictionary(
            try await materials().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var videos: [LibraryItemModel] = []
        var files: [AgentExportFile] = []
        for id in fields.items {
            guard let material = byID[id], case .video(let item)? = MaterialLibrary.row(material),
                item.historyItem == nil, let file = item.outputFile,
                FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
            else {
                files.append(
                    AgentExportFile(item: id, status: .skipped, message: "Not a video with a file on this Mac."))
                continue
            }
            videos.append(item)
        }
        let names = AgentExports.editingNames(
            for: videos, preset: preset, existing: AgentExports.existingNames(in: folder))
        for (item, name) in zip(videos, names) {
            files.append(
                await Self.write(item, as: name, preset: preset, into: folder, sidecar: fields.sidecar ?? true))
        }
        // In the order asked.
        let order = Dictionary(fields.items.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        files.sort { (order[$0.item] ?? 0) < (order[$1.item] ?? 0) }
        return AgentExported(folder: folder.path(percentEncoded: false), files: files)
    }

    private static func preset(_ preset: AgentExportPreset) -> ExportPreset {
        switch preset {
        case .premiere: .premiere
        case .davinciResolve: .davinciResolve
        case .finalCutPro: .finalCutPro
        case .editingH264: .editingH264
        }
    }

    /// Writes one take as Export for Editing does, under a name no file has.
    private static func write(
        _ item: LibraryItemModel, as name: ExportNaming.Names, preset: ExportPreset, into folder: URL,
        sidecar writesSidecar: Bool
    ) async -> AgentExportFile {
        guard let result = item.outputFile else {
            return AgentExportFile(item: item.id, status: .skipped, message: "Not a video with a file on this Mac.")
        }
        let video = folder.appending(path: name.video)
        let sidecar = writesSidecar ? folder.appending(path: name.sidecar) : nil
        do {
            let sidecarError = try await EditingExportModel.write(
                preset, item: item, result: result, to: video, sidecar: sidecar)
            return AgentExportFile(
                item: item.id, status: .done, file: video.path(percentEncoded: false),
                sidecar: sidecarError == nil ? sidecar?.path(percentEncoded: false) : nil,
                message: sidecarError.map { "The JSON sidecar wasn't written: \($0.localizedDescription)" })
        } catch {
            logger.error("Agent export failed: \(String(describing: error), privacy: .private)")
            return AgentExportFile(item: item.id, status: .failed, message: error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func materials() async throws(AgentError) -> [Material] {
        do {
            return try await environment.store.materials()
        } catch {
            logger.error("Can't read the library: \(String(describing: error), privacy: .private)")
            throw AgentError(
                .failed, message: "Jutsu Studio can't read its library right now.", retryable: true,
                next: "Try again in a moment.")
        }
    }

    private func deliverySets() async throws(AgentError) -> [DeliverySet] {
        do {
            return try await environment.store.deliverySets()
        } catch {
            throw AgentError(
                .failed, message: "Jutsu Studio can't read its delivery sets right now.", retryable: true,
                next: "Try again in a moment.")
        }
    }

    private static func kind(_ kind: AgentLibraryKind?) -> LibraryKind {
        switch kind {
        case .video?: .video
        case .image?: .image
        case .all?, nil: .all
        }
    }

    private static func kind(of operation: AgentEnhancement) -> PostAction.Kind {
        switch operation {
        case .upscale: .upscale
        case .reframe: .reframe
        case .removeBackground: .removeBackground
        case .dub: .dub
        case .changeVoice: .changeVoice
        }
    }

    private static func culling(_ verdict: AgentVerdict) -> Culling {
        switch verdict {
        case .unreviewed: .unreviewed
        case .kept: .kept
        case .rejected: .rejected
        }
    }

    private static func verdict(_ culling: Culling) -> AgentVerdict {
        switch culling {
        case .unreviewed: .unreviewed
        case .kept: .kept
        case .rejected: .rejected
        }
    }
}
