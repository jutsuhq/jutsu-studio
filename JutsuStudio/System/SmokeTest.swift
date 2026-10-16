import AppKit
import Foundation

/// `--smoke-test`: the release script launches the built app once and expects it to start and quit cleanly.
/// The app opens its library and first window as usual but never starts the queue or touches the network,
/// so it is safe on a maintainer's Mac with real jobs in the library.
enum SmokeTest {
    static let argument = "--smoke-test"
    static let launchedLine = "smoke-test: launched"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// Reports success once the first run-loop turns have passed, then quits with status 0.
    @MainActor
    static func finish(after delay: Duration = .seconds(3)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            FileHandle.standardOutput.write(Data((launchedLine + "\n").utf8))
            NSApp.terminate(nil)
        }
    }
}
