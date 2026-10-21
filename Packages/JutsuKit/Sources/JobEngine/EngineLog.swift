import Foundation

#if canImport(os)
    import os
#endif

/// `os.Logger` where it exists; Linux builds don't log.
/// `message` must hold no secrets; `detail` (error text, URLs) is logged as private.
struct EngineLog: Sendable {
    #if canImport(os)
        private let logger: Logger
    #endif

    init(category: String) {
        #if canImport(os)
            logger = Logger(subsystem: "com.jutsustudio", category: category)
        #endif
    }

    /// Something worth knowing that isn't a failure, such as a job held for the person.
    func notice(_ message: String) {
        #if canImport(os)
            logger.notice("\(message, privacy: .public)")
        #endif
    }

    func error(_ message: String, detail: String = "") {
        #if canImport(os)
            logger.error("\(message, privacy: .public) \(detail, privacy: .private)")
        #endif
    }

    func fault(_ message: String, detail: String) {
        #if canImport(os)
            logger.fault("\(message, privacy: .public) \(detail, privacy: .private)")
        #endif
    }
}
