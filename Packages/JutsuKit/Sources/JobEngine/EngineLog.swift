import Foundation

#if canImport(os)
    import os
#endif

/// `os.Logger` where it exists; Linux builds don't log.
/// `message` must hold no secrets; `detail` (error text, URLs) is logged as private.
struct EngineLog: Sendable {
    #if canImport(os)
        private let logger = Logger(subsystem: "com.jutsustudio", category: "JobEngine")
    #endif

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
