import Foundation
import JutsuCore

/// The IDs Higgsfield support asks for when a job went wrong.
public enum SupportIDs {
    /// "request_id=… correlation_id=… app=… build=… macos=…" for a failed or rejected job the API knows; `nil` for
    /// any other job. A missing field gets "none", so the line always has every field.
    public static func line(
        for job: Job,
        info: [String: Any]? = Bundle.main.infoDictionary,
        os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String? {
        switch job.state {
        case .failed, .rejected: break
        default: return nil
        }
        guard let remote = job.remote else { return nil }
        let version = info?["CFBundleShortVersionString"] as? String ?? "none"
        let build = info?["CFBundleVersion"] as? String ?? "none"
        return "request_id=\(remote.requestID) correlation_id=\(remote.correlationID ?? "none")"
            + " app=\(version) build=\(build) macos=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}
