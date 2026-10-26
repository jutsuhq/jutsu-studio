import Foundation
import JutsuAgent
import JutsuCore

/// An agent's `create_image` fields, checked against the connection's image models with the Image side of Create's
/// rules: never read from or written to the visible form.
public struct AgentImageOrder: Sendable, Hashable {
    /// `nil` takes the connection's first model, as the form does.
    public var model: String?
    public var prompt: String
    /// `nil` takes 1:1 when the model makes it, else its first frame.
    public var aspectRatio: String?
    /// `nil` makes one image.
    public var count: Int?
    /// The images to edit, in order.
    public var inputs: [LocalImage]
    /// The agent's name for the images, as it sent it; kept trimmed and cut (`JobSpec.title(from:)`).
    public var title: String?

    public init(
        model: String?, prompt: String, aspectRatio: String?, count: Int?, inputs: [LocalImage] = [],
        title: String? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.count = count
        self.inputs = inputs
        self.title = title
    }

    /// The request the form would send, or why it can't be sent, in English for the agent.
    func draft(models: [ImageModel], modelsAreSaved: Bool) -> Result<ReferenceGenerator.Draft, AgentImageRefusal> {
        guard !models.isEmpty else {
            return .failure(AgentImageRefusal("This connection offers no image models right now."))
        }
        if modelsAreSaved {
            return .failure(AgentImageRefusal("Jutsu Studio is still reading the image models; try again shortly."))
        }
        let chosen = model.map { id in models.first { $0.id == id } } ?? models.first
        guard let chosen else {
            let ids = models.map(\.id).joined(separator: ", ")
            return .failure(AgentImageRefusal("There's no image model \(model ?? ""). This connection offers \(ids)."))
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .failure(AgentImageRefusal("create_image needs prompt, the image to make."))
        }
        switch chosen.input {
        case .required where inputs.isEmpty:
            return .failure(AgentImageRefusal("\(chosen.id) edits an image: send inputs, the images to edit."))
        case .none where !inputs.isEmpty:
            return .failure(AgentImageRefusal("\(chosen.id) makes images from text only; leave out inputs."))
        default:
            break
        }
        if inputs.count > chosen.inputLimit {
            return .failure(
                AgentImageRefusal("\(chosen.id) takes at most \(chosen.inputLimit) input images, not \(inputs.count)."))
        }
        let ratio = aspectRatio ?? (chosen.aspectRatios.contains("1:1") ? "1:1" : chosen.aspectRatios.first)
        guard let ratio, chosen.aspectRatios.contains(ratio) else {
            let ratios = chosen.aspectRatios.joined(separator: ", ")
            return .failure(AgentImageRefusal("\(chosen.id) makes \(ratios), not \(aspectRatio ?? "any frame")."))
        }
        let count = count ?? chosen.variantCounts.first ?? 1
        guard chosen.variantCounts.contains(count) else {
            let counts = chosen.variantCounts.map(String.init).joined(separator: ", ")
            return .failure(AgentImageRefusal("\(chosen.id) makes \(counts) images per request, not \(count)."))
        }
        return .success(
            ReferenceGenerator.Draft(
                model: chosen, prompt: prompt, aspectRatio: ratio, count: count, inputs: inputs,
                title: JobSpec.title(from: title)))
    }
}

/// Why an agent's image request isn't taken: the request itself, or a log that can't be written.
public struct AgentImageRefusal: Error, Sendable, Hashable {
    public var message: String
    /// The request is fine, but Jutsu Studio can't record it, so nothing is sent.
    public var isNotSaved: Bool

    init(_ message: String, isNotSaved: Bool = false) {
        self.message = message
        self.isNotSaved = isNotSaved
    }
}

/// An agent's image request, as `agent-images.json` keeps it from the moment it is taken until 30 days after it
/// ended: what was asked, what the guard saw and whether it may have been sent.
public struct AgentImageRecord: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable {
        /// Taken, its price being read; nothing was sent.
        case pricing
        /// The guard stopped it; only the person sends it.
        case held
        /// Reserved and being sent: it may have reached the provider.
        case sending
        /// Accepted, its images being made.
        case following
        case finished, failed, canceled
    }

    /// Why it is held: one of the agent spending guard's holds, as a video job's, or the person's own daily cap.
    /// Stored as the case's name, as `AgentHold`'s raw values are: "overMaxCost", "priceAboveCap"…
    public enum Hold: Codable, Sendable, Hashable {
        case agent(AgentHold)
        /// It takes today past the person's own daily cap.
        case priceAboveCap

        public init(from decoder: any Decoder) throws {
            let name = try decoder.singleValueContainer().decode(String.self)
            if name == Self.priceAboveCapName {
                self = .priceAboveCap
            } else if let hold = AgentHold(rawValue: name) {
                self = .agent(hold)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No hold \(name)"))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .agent(let hold): try container.encode(hold.rawValue)
            case .priceAboveCap: try container.encode(Self.priceAboveCapName)
            }
        }

        private static let priceAboveCapName = "priceAboveCap"
    }

    /// Also the image run's ID: what `jobs` and `job_action` take.
    public let id: UUID
    public var origin: AgentOrigin
    public var providerKind: ProviderKind
    public var owner: String?
    public var model: ImageModel
    public var prompt: String
    public var aspectRatio: String
    public var count: Int
    /// The first image to edit. A request of one image keeps only this, which is all a 0.2.0 record holds.
    public var input: LocalImage?
    /// Every image to edit, in order, when there are several; `nil` for one or none.
    public var severalInputs: [LocalImage]?
    public var state: State
    public var hold: Hold?
    /// The price the guard last saw.
    public var price: Cost?
    public var priceIsKnown: Bool
    /// The price the person agreed to with Send on a held request.
    public var approvedPrice: Cost?
    /// Saved with the reservation, right before the submit: from then on it may have been sent.
    public var sentAt: Date?
    public var error: String?
    public var createdAt: Date
    public var finishedAt: Date?
    /// The agent's name for the images; `nil` without one, and in records from before it.
    public var title: String?

    /// The images to edit, in order.
    public var inputs: [LocalImage] { severalInputs ?? input.map { [$0] } ?? [] }

    var draft: ReferenceGenerator.Draft {
        ReferenceGenerator.Draft(
            model: model, prompt: prompt, aspectRatio: aspectRatio, count: count, inputs: inputs, title: title)
    }

    /// It may have reached the provider, so its price counts.
    public var mayHaveBeenSent: Bool { sentAt != nil }

    public var isOver: Bool { [.finished, .failed, .canceled].contains(state) }
}

extension AgentJob {
    /// An agent's image request as `jobs` sees it.
    /// - Parameter files: its images saved in Library › Images.
    public init(_ record: AgentImageRecord, files: [URL]) {
        let state =
            switch record.state {
            case .pricing: "preparing"
            case .held: "paused"
            case .sending, .following: "processing"
            case .finished: files.isEmpty ? "downloading" : "done"
            case .failed: "failed"
            case .canceled: "canceled"
            }
        self.init(
            id: record.id, state: state, kind: "image", requestID: record.origin.requestID,
            client: record.origin.client, mode: "image", model: record.model.id, createdAt: record.createdAt,
            finishedAt: record.finishedAt)
        if record.state == .held {
            pauseReason = record.hold == .priceAboveCap ? "price_above_cap" : "agent_limit"
            hold = record.hold.flatMap(Self.name(of:))
            needsPerson = true
        }
        price = record.price.flatMap(AgentMoney.init).map(AgentAmount.init)
        isPriceExact = record.priceIsKnown
        charged = record.mayHaveBeenSent
        error = record.state == .failed ? record.error : nil
        result = files.first?.path(percentEncoded: false)
        results = files.isEmpty ? nil : files.map { $0.path(percentEncoded: false) }
    }

    /// The agent hold's name; nil for the person's cap, which `pauseReason` names.
    static func name(of hold: AgentImageRecord.Hold) -> String? {
        guard case .agent(let hold) = hold else { return nil }
        return name(of: hold)
    }
}
