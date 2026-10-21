import Foundation
import JutsuCore

// A submit refused for inputs that weren't uploaded: the job uploads them and sends the submit once more.
extension JobEngine {
    /// Whether a refused submit is sent again with uploaded inputs: reused media IDs, a result named by its job ID,
    /// media the account already keeps, or files sent by their link. Only a `validation` refusal of those inputs counts, and each fallback happens
    /// once, since the job then forgets what it sent.
    /// Records a submit that failed with `error` (anything but `outcomeUnknown`). A refusal sent nothing to pay for,
    /// so the submit marker goes. A lost answer to a submit with the key keeps it: the request may be running, so it
    /// is resent with the same key and can't be canceled as never sent. Returns `true` when the job was set to upload
    /// its inputs again (`uploadsAfterRefusal`).
    func settleFailedSubmit(
        _ error: ProviderError, of job: Job, inputs: RemoteInputs, isIdempotent: Bool
    ) async throws -> Bool {
        if !(isIdempotent && Self.mayHaveBeenTaken(error)) { try await save(job.id) { $0.submitAttempt = nil } }
        // Only a refusal certainly sent nothing to pay for: an agent's reservation for it goes back to the budget.
        if !Self.mayHaveBeenTaken(error), let reservation = jobs[job.id]?.agent?.reservation {
            await releaseAgentSpend(reservation, of: job.id)
            try await save(job.id) { $0.agent?.reservation = nil }
        }
        return try await uploadsAfterRefusal(error, of: job, inputs: inputs)
    }

    /// A failure that can come after the server took the request: no answer, or a server error.
    static func mayHaveBeenTaken(_ error: ProviderError) -> Bool {
        switch error {
        case .network, .outcomeUnknown: true
        case .server(let status): status >= 500 || status < 400
        default: false
        }
    }

    func uploadsAfterRefusal(_ error: ProviderError, of job: Job, inputs: RemoteInputs) async throws -> Bool {
        guard case .validation = error else { return false }
        if let reused = job.spec.remoteInputs, inputs == reused {
            try await uploadAgain(job)
        } else if Self.namesResultByJobID(job.spec), inputs.video == nil {
            try await uploadInsteadOfJobID(job)
        } else if Self.usesServerMedia(inputs, of: job.spec) {
            try await uploadInsteadOfServerMedia(job)
        } else if Self.usesLinks(inputs, of: job.spec) {
            try await uploadInsteadOfLinking(job)
        } else {
            return false
        }
        return true
    }

    /// The provider refused media IDs reused from another generation, e.g. because it no longer keeps the
    /// files. The next submit downloads and uploads them again, once: the job stops reusing them.
    func uploadAgain(_ job: Job) async throws {
        let id = job.id
        try Self.checkReusedInputs(job.spec)
        log.error("Job \(id): reused inputs were refused, uploading them again")
        await releaseSlot(id)
        try await save(id) {
            $0.spec.remoteInputs = nil
            $0.inputs = nil
            $0.serverPrice = nil
        }
    }

    /// An operation on a result the account made names it by its job ID, so nothing is prepared or uploaded.
    static func namesResultByJobID(_ spec: JobSpec) -> Bool {
        spec.remoteInputs == nil && spec.operation?.sourceJobID != nil
    }

    /// Nothing is prepared or uploaded: an operation names its result by its job ID, and a draft's finalize names the
    /// draft (`JobSpec.draftJobID`), which no upload can stand in for.
    static func uploadsNothing(_ spec: JobSpec) -> Bool {
        spec.draftJobID != nil || namesResultByJobID(spec)
    }

    /// The provider refused the job ID an operation named its result by, e.g. because the tool takes only uploads.
    /// The next submit uploads the result's file instead, once: the job forgets the ID.
    func uploadInsteadOfJobID(_ job: Job) async throws {
        let id = job.id
        log.error("Job \(id): the result's job ID was refused, uploading the file instead")
        await releaseSlot(id)
        try await save(id) {
            $0.spec.operation?.sourceJobID = nil
            $0.inputs = nil
            $0.serverPrice = nil
        }
    }

    /// Whether `inputs` name any reference by the media the account already keeps (`LocalImage.serverMedia`).
    static func usesServerMedia(_ inputs: RemoteInputs, of spec: JobSpec) -> Bool {
        let ids = Set(spec.references.compactMap(\.serverMedia?.id))
        return inputs.images.contains { $0.id.map(ids.contains) == true }
    }

    /// The provider refused the media IDs of an element's images, e.g. because the element was deleted. The next
    /// submit uploads the downloaded files instead, once: the job forgets the media.
    func uploadInsteadOfServerMedia(_ job: Job) async throws {
        let id = job.id
        log.error("Job \(id): the account's media IDs were refused, uploading the files instead")
        await releaseSlot(id)
        try await save(id) {
            for index in $0.spec.references.indices { $0.spec.references[index].serverMedia = nil }
            $0.inputs = nil
            $0.serverPrice = nil
        }
    }

    /// Whether `inputs` name any input by the link its file was downloaded from rather than by an upload.
    static func usesLinks(_ inputs: RemoteInputs, of spec: JobSpec) -> Bool {
        let origins = Set([spec.source?.remoteOrigin].compactMap(\.self) + spec.references.compactMap(\.remoteOrigin))
        return inputs.video.map { origins.contains($0.url) } == true
            || inputs.images.contains { origins.contains($0.url) }
    }

    /// The provider refused an input sent by its link, e.g. because the host doesn't serve it to Higgsfield. The
    /// next submit uploads the files instead, once: the job forgets where they came from.
    func uploadInsteadOfLinking(_ job: Job) async throws {
        let id = job.id
        log.error("Job \(id): linked inputs were refused, uploading them instead")
        await releaseSlot(id)
        try await save(id) {
            $0.spec.source?.remoteOrigin = nil
            for index in $0.spec.references.indices { $0.spec.references[index].remoteOrigin = nil }
            $0.inputs = nil
            $0.serverPrice = nil
        }
    }
}
