import Foundation

/// A voice a result's speaker can be changed to (Change Voice).
public struct AccountVoice: Sendable, Hashable, Identifiable {
    public var choice: VoiceChoice
    /// A short sample to listen to; `nil` when the provider gives none.
    public var previewURL: URL?

    public init(choice: VoiceChoice, previewURL: URL? = nil) {
        self.choice = choice
        self.previewURL = previewURL
    }

    public var id: String { "\(choice.type)/\(choice.id)" }
}

/// A provider whose account lists the voices Change Voice takes: built-in ones and the account's own.
public protocol VoiceLibrary: Sendable {
    /// Every voice, in the provider's order. Read once per connection; later calls answer from that read.
    func voices() async throws -> [AccountVoice]
}
