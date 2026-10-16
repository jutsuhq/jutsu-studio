import Foundation

/// Why a job failed. The app's own reasons are cases, so they are recognised without comparing text and are worded
/// in the language the app shows them in (Presentation); a reason the server or a provider gave is kept as its text.
/// Engine steps throw it to fail their job with it.
public enum FailureReason: Error, Sendable, Hashable {
    /// The provider didn't finish the job within the generation deadline. It may still finish and charge for it,
    /// so the job is checked again rather than submitted again (`Job.mayStillFinish`).
    case deadline
    /// A submit may have reached the server and was never answered, or a cancel cut it off.
    case outcomeUnknown
    /// A submit without an idempotency key was cut off by a quit, crash or pause, so the server may have started it.
    case submitCutOff
    /// The disk filled up before the job was submitted; nothing was charged.
    case notEnoughDiskSpace
    /// The finished result expired on the server.
    case outputUnavailable
    /// An input reused from an earlier generation is gone from the server.
    case inputUnavailable
    /// An input reused from an earlier generation doesn't point to an https address.
    case insecureInput
    /// Refused by content moderation before the provider accepted the job.
    case contentModeration
    /// The provider reported the generation as failed without saying why.
    case generationFailed
    /// The provider canceled a job that could no longer be canceled from the app.
    case canceledOnServer
    /// A bug in the app, or an error that has no description to show.
    case internalError
    /// Text from the server or a provider, shown as it came.
    case message(String)
}

// A message is stored as its plain text, the shape every stored reason had before the cases existed; the app's own
// reasons as `{"code": …}`, which no text can be mistaken for. A code this version doesn't know (written by a newer
// one) reads as `internalError`, so the job still loads.
extension FailureReason: Codable {
    private struct Coded: Codable {
        var code: String
    }

    /// Every reason but `message`.
    static let coded: [FailureReason] = [
        .deadline, .outcomeUnknown, .submitCutOff, .notEnoughDiskSpace, .outputUnavailable, .inputUnavailable,
        .insecureInput, .contentModeration, .generationFailed, .canceledOnServer, .internalError,
    ]

    /// The stored name of a reason of the app's own; `nil` for a message. Never change one: stored jobs hold it.
    private var code: String? {
        switch self {
        case .deadline: "deadline"
        case .outcomeUnknown: "outcomeUnknown"
        case .submitCutOff: "submitCutOff"
        case .notEnoughDiskSpace: "notEnoughDiskSpace"
        case .outputUnavailable: "outputUnavailable"
        case .inputUnavailable: "inputUnavailable"
        case .insecureInput: "insecureInput"
        case .contentModeration: "contentModeration"
        case .generationFailed: "generationFailed"
        case .canceledOnServer: "canceledOnServer"
        case .internalError: "internalError"
        case .message: nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .message(text)
        } else {
            let code = try container.decode(Coded.self).code
            self = Self.coded.first { $0.code == code } ?? .internalError
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .message(let text) = self {
            try container.encode(text)
        } else {
            try container.encode(Coded(code: code ?? "internalError"))
        }
    }
}
