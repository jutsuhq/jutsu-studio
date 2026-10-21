import Foundation

#if canImport(os)
    import os
#endif

/// `os.Logger` where it exists, as JobEngine's `EngineLog`; Linux builds don't log.
/// `message` must hold no secrets; `detail` (error text, URLs) is logged as private.
struct PresentationLog: Sendable {
    #if canImport(os)
        private let logger: Logger
    #endif

    init(category: String) {
        #if canImport(os)
            logger = Logger(subsystem: "com.jutsustudio", category: category)
        #endif
    }

    func error(_ message: String, detail: String = "") {
        #if canImport(os)
            logger.error("\(message, privacy: .public) \(detail, privacy: .private)")
        #endif
    }
}
