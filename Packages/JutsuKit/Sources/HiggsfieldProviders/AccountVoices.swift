import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

extension HiggsfieldMCPProvider: VoiceLibrary {
    /// Every page of `list_voices`, read once for this connection: a sign-out or another sign-in builds a new
    /// provider, so another account's voices never show. A failed read isn't kept.
    public func voices() async throws -> [AccountVoice] {
        if let cachedVoices { return cachedVoices }
        var voices: [AccountVoice] = []
        var cursor: JSONValue?
        var pages = 0
        repeat {
            let page = try await mapped { try await account.voices(cursor: cursor, size: Self.voicePageSize) }
            voices += page.items.map(Self.voice)
            pages += 1
            // An empty page that still names a next one would never end.
            cursor = page.items.isEmpty ? nil : page.nextCursor
        } while cursor != nil && pages < Self.maxVoicePages
        cachedVoices = voices
        return voices
    }

    /// The largest page `list_voices` takes.
    static let voicePageSize = 100
    /// note: stops after 500 voices; a longer list would need a search field and a paged list in the sheet.
    static let maxVoicePages = 5

    static func voice(_ voice: Voice) -> AccountVoice {
        AccountVoice(
            choice: VoiceChoice(id: voice.id, type: voice.type, name: voice.name), previewURL: voice.previewURL)
    }
}
