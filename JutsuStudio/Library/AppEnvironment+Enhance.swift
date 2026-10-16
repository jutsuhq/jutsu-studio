import Foundation
import JutsuCore

extension AppEnvironment {
    /// The voices Change Voice offers; `nil` while disconnected, with an API key, or when the list can't be read.
    /// The provider reads the list once per connection.
    func voices() async -> [AccountVoice]? {
        guard let library = voiceLibrary else { return nil }
        do {
            return try await library.voices()
        } catch {
            libraryLogger.error("Can't list the voices: \(String(describing: error), privacy: .private)")
            return nil
        }
    }
}
