import Foundation
import HiggsfieldCore
import JutsuCore

// The reason a job fails with for an error no step handles, and the check that keeps reused inputs on https.
extension JobEngine {
    /// Out of disk space before submit; else the error's own description: a `LocalizedError`'s (`MediaError`,
    /// `JobEngineError`), or Foundation's for a file system error. An error without one is a bug to the user.
    static func failureReason(for error: any Error) -> FailureReason {
        if isOutOfSpace(error) { return .notEnoughDiskSpace }
        if let description = (error as? any LocalizedError)?.errorDescription { return .message(description) }
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain else { return .internalError }
        return .message(error.localizedDescription)
    }

    /// The disk or the user's quota is full: `NSFileWriteOutOfSpaceError`, `ENOSPC` or `EDQUOT`, also as the
    /// underlying error of another one.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, CocoaError.fileWriteOutOfSpace.rawValue),
            (NSPOSIXErrorDomain, Int(ENOSPC)), (NSPOSIXErrorDomain, Int(EDQUOT)):
            return true
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error else { return false }
            return isOutOfSpace(underlying)
        }
    }

    /// Inputs reused from the provider are downloaded, never read as local files, so each must be https:
    /// a `file:` URL among them came from the server, not from the user.
    static func checkReusedInputs(_ spec: JobSpec) throws {
        guard let reused = spec.remoteInputs else { return }
        let urls =
            [reused.video?.url, spec.source?.fileURL].compactMap(\.self) + reused.images.map(\.url)
            + spec.references.map(\.fileURL)
        guard urls.allSatisfy(\.isHTTPS) else {
            throw FailureReason.insecureInput
        }
    }
}
