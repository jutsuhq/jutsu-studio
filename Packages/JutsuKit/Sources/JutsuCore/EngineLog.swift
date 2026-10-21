import Foundation

#if canImport(os)
    import os
#endif

/// `os.Logger` for the packages that also build on Linux (JobEngine, Presentation); Linux builds don't log.
/// `message` must hold no secrets; `detail` (error text, URLs) is logged as private.
public struct EngineLog: Sendable {
    #if canImport(os)
        private let logger: Logger
    #endif

    public init(category: String) {
        #if canImport(os)
            logger = Logger(subsystem: "com.jutsustudio", category: category)
        #endif
    }

    /// Something worth knowing that isn't a failure, such as a job held for the person.
    public func notice(_ message: String) {
        #if canImport(os)
            logger.notice("\(message, privacy: .public)")
        #endif
    }

    public func error(_ message: String, detail: String = "") {
        #if canImport(os)
            logger.error("\(message, privacy: .public) \(detail, privacy: .private)")
        #endif
    }

    public func fault(_ message: String, detail: String) {
        #if canImport(os)
            logger.fault("\(message, privacy: .public) \(detail, privacy: .private)")
        #endif
    }
}
