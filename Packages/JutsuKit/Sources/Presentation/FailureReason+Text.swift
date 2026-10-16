import Foundation
import JutsuCore

extension FailureReason {
    /// What a failed job's row says, in the language the app shows now; a message as it came, "Failed" when empty.
    public var text: String {
        switch self {
        case .deadline:
            String(
                localized:
                    "Higgsfield didn't finish this job in time. Check the result in your generations on Higgsfield.",
                bundle: .module)
        case .outcomeUnknown:
            String(
                localized: "Higgsfield may have started this job. Check your generations there before trying again.",
                bundle: .module)
        case .submitCutOff:
            String(
                localized: """
                    Jutsu Studio stopped while sending this job, so Higgsfield may have started it. Look for it in \
                    your Higgsfield history in Library before you retry: if it started, a retry is charged again.
                    """, bundle: .module)
        case .notEnoughDiskSpace:
            String(
                localized: "Not enough disk space to prepare this job. Free up space on your Mac, then retry.",
                bundle: .module)
        case .outputUnavailable:
            String(
                localized:
                    "The result is no longer available on Higgsfield. Results expire about 7 days after they finish.",
                bundle: .module)
        case .inputUnavailable:
            String(
                localized: "An input of this job is no longer available on Higgsfield. Add the files again to run it.",
                bundle: .module)
        case .insecureInput:
            String(
                localized:
                    "An input of this job doesn't point to a secure Higgsfield address. Add the files again to run it.",
                bundle: .module)
        case .contentModeration:
            String(localized: "Rejected by content moderation.", bundle: .module)
        case .generationFailed:
            String(localized: "The generation failed.", bundle: .module)
        case .canceledOnServer:
            String(localized: "Canceled on the server.", bundle: .module)
        case .internalError:
            String(localized: "Internal error.", bundle: .module)
        case .message(let text):
            Self.shown(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shown(_ message: String) -> String {
        message.isEmpty ? String(localized: "Failed", bundle: .module) : message
    }
}
