import Foundation
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// What the paid commands share before anything is queued: an upload's admission, the request record, and the
// inbox the helper's files arrive in.
extension AgentService {
    // MARK: Uploads

    /// Checks an upload's request before a byte of it is read: only commands with files take one, a request ID taken by
    /// other parameters is refused (`request_conflict`), and one already queued with these needs no file again
    /// (`request_known`).
    func admit(_ upload: UploadCommand) throws(AgentError) {
        let commands = ["create_video", "create_image", "create_element", "frames"]
        guard let request = upload.request, commands.contains(request.command) else {
            throw AgentError(
                .fileRefused, message: "Only create_video, create_image, create_element and frames take files.",
                retryable: false, next: "Send files with create_video, create_image, create_element or frames.")
        }
        // Free and never logged as a request: its files are removed once its frames are written.
        if request.command == "frames" { return }
        let state: AgentRequestGate<AgentCreated, AgentError>.State
        do {
            state = try requests.state(
                of: request.requestID, fingerprint: request.fingerprint, parameters: request.parameters)
        } catch {
            logger.error("Can't read the agent requests: \(error.localizedDescription, privacy: .private)")
            throw Self.requestsUnreadable
        }
        switch state {
        case .new, .running: return
        case .conflict: throw .requestConflict
        // Sent again with another max_cost: its job has the files already, whatever the new one decides.
        case .known, .otherMaxCost:
            throw AgentError(
                .requestKnown, message: "This request was already queued; its files aren't needed again.",
                retryable: false, next: "Send \(request.command) without uploading to get its job.")
        }
    }

    static let requestsUnreadable = AgentError(
        .failed, message: "Jutsu Studio can't read its record of agent requests, so nothing is queued.",
        retryable: true, next: "Ask the person to check the app's data folder, then send the request again.")

    /// What the request gate answers a paid command with instead of running it.
    static func refusals(_ command: String, made: String) -> AgentRequestGate<AgentCreated, AgentError>.Refusals {
        AgentRequestGate.Refusals(
            conflict: .requestConflict, unreadable: requestsUnreadable,
            neverQueued: AgentError(
                .failed, message: "The request was recorded but \(made).", retryable: true,
                next: "Send the same \(command) again."))
    }

    /// Records the request with the IDs of what it makes, before anything is queued or sent.
    func recordRequest(
        _ requestID: String, fingerprint: String, parameters: String? = nil, jobIDs: [UUID], kind: String? = nil
    ) throws(AgentError) {
        do {
            try requests.record(
                requestID, fingerprint: fingerprint, parameters: parameters, ids: jobIDs, at: .now, kind: kind)
        } catch {
            throw AgentError(
                .failed, message: "Jutsu Studio can't record the request, so nothing is queued or sent.",
                retryable: true, next: "Ask the person to check the Mac has room, then send the request again.")
        }
    }

    /// A path the helper's upload answered with: a file in the app's own inbox, and nowhere else.
    func inboxFile(_ path: String) throws(AgentError) -> URL {
        guard let inbox = server?.inbox, inbox.uploadFolder(of: path) != nil,
            FileManager.default.fileExists(atPath: path)
        else {
            throw AgentError(
                .fileRefused, message: "\(path) isn't a file the helper sent to Jutsu Studio.", retryable: false,
                next: "Pass the file's path on this Mac; the jutsu helper sends it to the app.")
        }
        return URL(filePath: path)
    }

    func discard(_ files: [String]) {
        server?.inbox.remove(files)
    }

    /// Removes the inbox's files that no job still reads, a day after they came: refused requests, and jobs gone
    /// from the store or finished more than a week ago. Skipped when the store can't be read.
    func sweepInbox() async {
        guard let inbox = server?.inbox else { return }
        let now = Date.now
        do {
            let jobs = try await environment.store.jobsUnfinishedOrFinished(since: now.addingTimeInterval(-7 * 86_400))
            let kept: [String] =
                jobs.flatMap { job -> [String] in
                    let files: [URL?] = [job.spec.source?.fileURL] + job.spec.references.map(\.fileURL)
                    return files.compactMap { $0?.path(percentEncoded: false) }
                }
                + ((try? environment.agentImages.records()) ?? []).filter { !$0.isOver }
                .flatMap { $0.inputs.map { $0.fileURL.path(percentEncoded: false) } }
            let removed = inbox.sweep(keeping: Set(kept), before: now.addingTimeInterval(-86_400))
            if removed > 0 { logger.info("Removed \(removed, privacy: .private) old agent upload(s)") }
        } catch {
            logger.error("Can't check the agent inbox: \(String(describing: error), privacy: .private)")
        }
    }
}
