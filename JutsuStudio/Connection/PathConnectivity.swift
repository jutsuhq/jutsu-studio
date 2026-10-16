import Foundation
import JutsuCore
import Network

/// `Connectivity` on `NWPathMonitor`. Each stream owns its monitor; the monitor reports the current
/// path right after `start`, which gives the "current state first" the port promises.
struct PathConnectivity: Connectivity {
    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.jutsustudio.connectivity"))
        }
    }
}
