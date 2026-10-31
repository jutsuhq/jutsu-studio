import Foundation
import JutsuAgent
import JutsuCore

/// create_element: publishes an agent's images as one reference element of the account, as Save to Higgsfield…
/// does, once for its request ID. Higgsfield names the element only in its answer, so the request is recorded before
/// anything is sent under an ID of its own (`sentKind`), and again under the element's ID once Higgsfield answered
/// (`kind`): a request whose answer never came is never sent a second time.
@MainActor
public struct AgentElementMaking {
    /// The `kind` of a request recorded with the element it made.
    public static let kind = "element"
    /// The `kind` of a request sent to Higgsfield whose answer isn't recorded.
    public static let sentKind = "element_sent"

    private let requests: AgentRequestGate<AgentCreated, AgentError>
    private let source: any AccountElements
    private let upload: (LocalImage) async throws -> RemoteAsset
    private let refusals: AgentRequestGate<AgentCreated, AgentError>.Refusals
    private let events = PresentationLog(category: "Agents")

    /// - Parameters:
    ///   - source: the account's elements, which publish (`HiggsfieldMCPProvider.offersReferenceElements`).
    ///   - upload: uploads an image to the account as Save to Higgsfield… does (`elementUploader`).
    public init(
        requests: AgentRequestGate<AgentCreated, AgentError>, source: any AccountElements,
        upload: @escaping (LocalImage) async throws -> RemoteAsset,
        refusals: AgentRequestGate<AgentCreated, AgentError>.Refusals
    ) {
        self.requests = requests
        self.source = source
        self.upload = upload
        self.refusals = refusals
    }

    /// The element the request makes, or made when it is known.
    /// - Parameters:
    ///   - images: the request's images, read only for a new request: one already known sends none.
    ///   - discard: called once the request's files aren't needed, made or not.
    public func create(
        _ fields: CreateElementCommand, images: @escaping @MainActor () throws(AgentError) -> [LocalImage],
        discard: () -> Void
    ) async throws(AgentError) -> AgentCreated {
        let created = try await requests.run(
            fields.requestID, fingerprint: fields.fingerprint, refusals: refusals, discard: discard,
            known: { ids throws(AgentError) in
                guard let id = ids.first else { return nil }
                return try await made(id, of: fields)
            },
            queue: { () throws(AgentError) in try await make(fields, images: try images()) })
        // Higgsfield keeps the images now.
        discard()
        return created
    }

    private func make(_ fields: CreateElementCommand, images: [LocalImage]) async throws(AgentError) -> AgentCreated {
        let category = fields.category.flatMap(ElementCategory.init(rawValue:)) ?? .character
        try record(fields, id: UUID(), kind: Self.sentKind)
        let element: AccountElement
        do {
            var assets: [RemoteAsset] = []
            for image in images { assets.append(try await upload(image)) }
            element = try await source.createElement(
                name: SavedElement.name(fields.name), category: category, images: assets)
        } catch {
            events.error("An agent's element wasn't made", detail: String(describing: error))
            throw AgentError(
                .failed, message: "Higgsfield didn't make the element: \(error.localizedDescription)",
                retryable: true,
                next: "Call elements with query \(fields.name) to check it wasn't made after all, then send the same "
                    + "create_element again.")
        }
        if let id = UUID(uuidString: element.id) {
            do throws(AgentError) {
                try record(fields, id: id, kind: Self.kind)
            } catch {
                events.error("An agent's element can't be recorded", detail: error.message)
            }
        }
        return AgentCreated(requestID: fields.requestID, known: false, jobs: [], element: Self.agentElement(element))
    }

    /// The element a known request made, as the account has it now; `nil` when the log names none.
    private func made(_ id: UUID, of fields: CreateElementCommand) async throws(AgentError) -> AgentCreated? {
        switch requests.kind(of: id) {
        case Self.kind:
            let element: AccountElement
            do {
                element = try await source.elementImages(
                    AccountElement(id: id.uuidString.lowercased(), name: fields.name))
            } catch {
                throw AgentError(
                    .failed, message: "Higgsfield didn't return the element: \(error.localizedDescription)",
                    retryable: true, next: "Try again in a moment.")
            }
            return AgentCreated(requestID: fields.requestID, known: true, jobs: [], element: Self.agentElement(element))
        case Self.sentKind:
            throw AgentError(
                .failed,
                message: "This request was sent to Higgsfield, but whether it made the element isn't known: its "
                    + "answer never came.",
                retryable: false,
                next: "Call elements with query \(fields.name) in a minute; if it isn't there, send create_element "
                    + "with a new request_id.")
        default:
            return nil
        }
    }

    private func record(_ fields: CreateElementCommand, id: UUID, kind: String) throws(AgentError) {
        do {
            try requests.record(fields.requestID, fingerprint: fields.fingerprint, ids: [id], at: .now, kind: kind)
        } catch {
            throw AgentError(
                .failed, message: "Jutsu Studio can't record the request, so nothing is sent.", retryable: true,
                next: "Ask the person to check the Mac has room, then send the request again.")
        }
    }

    static func agentElement(_ element: AccountElement) -> AgentElement {
        AgentElement(
            id: element.id, name: element.name, category: element.category?.rawValue,
            imageCount: element.images.isEmpty ? nil : element.images.count, status: element.status)
    }
}
