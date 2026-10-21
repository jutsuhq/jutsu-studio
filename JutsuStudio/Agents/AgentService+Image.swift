import Foundation
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// create_image: images made as the Image side of Create makes them (`AgentImageOrder`), never through its visible
// form, and sent through Generate…'s own runs behind the agents' spending guard (`AgentImageQueue`).
extension AgentService {
    func createImage(_ fields: CreateImageCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let files = [fields.image.input].compactMap(\.self)
        if let running = creatingImages[fields.requestID] {
            guard running.fingerprint == fields.fingerprint else {
                discard(files)
                throw .requestConflict
            }
            return try await running.task.value.get()
        }
        switch try lookup(fields.requestID, fingerprint: fields.fingerprint) {
        case .conflict:
            discard(files)
            throw .requestConflict
        case .known(let ids):
            discard(files)
            var jobs: [AgentJob] = []
            for id in ids { if let job = await imageJob(id) { jobs.append(job) } }
            guard jobs.isEmpty else { return AgentCreated(requestID: fields.requestID, known: true, jobs: jobs) }
            // Recorded, but the app quit before the request was: nothing was sent, so it is forgotten and sent again.
            try? environment.agentRequests.remove(fields.requestID)
            throw AgentError(
                .failed, message: "The request was recorded but never taken.", retryable: true,
                next: "Send the same create_image again.")
        case .new:
            break
        }
        let task = Task { [weak self] () -> Result<AgentCreated, AgentError> in
            guard let self else { return .failure(.agentsOff) }
            do throws(AgentError) {
                return .success(try await self.queueImage(fields, client: client))
            } catch {
                return .failure(error)
            }
        }
        creatingImages[fields.requestID] = (fields.fingerprint, task)
        defer { creatingImages[fields.requestID] = nil }
        let result = await task.value
        if case .failure = result { discard(files) }
        let created = try result.get()
        logger.info("Agent \(client ?? "unnamed", privacy: .private) asked for images")
        return created
    }

    /// Records the request with its run's ID, then hands it to the queue; one that can't be taken is forgotten, so
    /// the agent can fix it and send it again.
    private func queueImage(_ fields: CreateImageCommand, client: String?) async throws(AgentError) -> AgentCreated {
        guard let kind = environment.connection.state.kind, let provider = environment.imageProvider else {
            throw Self.notConnected
        }
        if let blocker = environment.referenceGenerationBlocker {
            throw AgentError(.notApplicable, message: blocker, retryable: true, next: "Try again in a moment.")
        }
        try Self.checkUnit(of: fields.maxCost, on: kind)
        let input = try fields.image.input.map { path throws(AgentError) in LocalImage(fileURL: try inboxFile(path)) }
        let image = fields.image
        let order = AgentImageOrder(
            model: image.model, prompt: image.prompt, aspectRatio: image.aspectRatio, count: image.count,
            input: input)
        let id = UUID()
        try recordRequest(fields.requestID, fingerprint: fields.fingerprint, jobIDs: [id])
        let origin = AgentOrigin(
            client: client, requestID: fields.requestID,
            maxCost: AgentMoney(fields.maxCost.amount, Self.unit(of: fields.maxCost.unit)))
        do throws(AgentImageRefusal) {
            _ = try environment.agentImages.create(
                order, id: id, origin: origin, provider: provider, upload: environment.imageUploader(provider))
        } catch {
            try? environment.agentRequests.remove(fields.requestID)
            throw error.isNotSaved
                ? AgentError(.failed, message: error.message, retryable: true, next: "Send the request again.")
                : AgentError.invalidRequest(error.message)
        }
        let jobs = await imageJob(id).map { [$0] } ?? []
        return AgentCreated(requestID: fields.requestID, known: false, jobs: jobs)
    }

    /// An agent's image request as `jobs` lists it; `nil` when there is no such request.
    func imageJob(_ id: UUID) async -> AgentJob? {
        guard let record = environment.agentImages.record(id) else { return nil }
        let files = await imageFiles(of: record)
        let status = AgentJobStatus(record, files: files)
        return AgentJob(
            id: id, state: status.state, pauseReason: status.pauseReason, hold: status.hold,
            needsPerson: status.needsPerson, progress: nil,
            price: status.price.map { AgentAmount($0.amount, Self.unit(of: $0.unit)) },
            isPriceExact: status.isPriceExact, charged: status.charged, error: status.error, result: status.result,
            results: files.isEmpty ? nil : files.map { $0.path(percentEncoded: false) }, kind: "image",
            requestID: record.origin.requestID, client: record.origin.client, mode: "image", model: record.model.id,
            createdAt: record.createdAt, finishedAt: record.finishedAt)
    }

    /// The images a finished request saved in Library › Images: this session's results, else the catalog's images
    /// of the request (`variantGroupID`).
    private func imageFiles(of record: AgentImageRecord) async -> [URL] {
        let session = environment.agentImages.files(of: record.id)
        guard session.isEmpty, record.state == .finished else { return session }
        let materials = (try? await environment.store.materials()) ?? []
        return materials.filter { $0.kind == .image && $0.variantGroupID == record.id && !$0.isHidden }
            .compactMap(\.current.fileURL)
    }

    /// `job_action` on an image request: cancel only. A request runs as soon as it is taken, and a retry would be a
    /// new paid request, which only `create_image` with a new `request_id` makes.
    func actOnImage(_ action: AgentJobAction, _ id: UUID) async throws(AgentError) -> AgentActed {
        switch action {
        case .cancel:
            guard environment.agentImages.cancel(id) else {
                throw AgentError(
                    .notApplicable, message: "The image request is already over.", retryable: false,
                    next: "Call jobs to see how it ended.")
            }
            return AgentActed(action: action, job: await imageJob(id))
        case .retry:
            throw AgentError(
                .notApplicable, message: "An image request isn't retried.", retryable: false,
                next: "Send create_image again with a new request_id.")
        case .runNext:
            throw AgentError(
                .notApplicable, message: "Image requests don't wait in the queue.", retryable: false,
                next: "Call jobs to follow it.")
        case .pauseQueue, .resumeQueue:
            throw .badRequest("\(action.rawValue) takes no job")
        }
    }

    /// The image models Create offers on this connection, as last read; never a network call.
    func imageModels() -> [AgentCapabilities.ImageModel] {
        environment.referenceGenerator.models.map { model in
            let input =
                switch model.input {
                case .none: "none"
                case .optional: "optional"
                case .required: "required"
                }
            return AgentCapabilities.ImageModel(
                id: model.id, title: model.title, counts: model.variantCounts, aspectRatios: model.aspectRatios,
                input: input)
        }
    }
}
