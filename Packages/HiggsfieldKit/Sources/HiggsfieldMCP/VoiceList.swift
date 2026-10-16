import Foundation
import HiggsfieldCore

// `list_voices` as the live catalog of 2026-10-15 describes it (`docs/mcp-snapshots/2026-10-15.json`): `cursor` and
// `size` (1–100) in; `voices` (each with `voice_id`, `voice_type` "preset" or "element", `name`, `gender`,
// `preview_url`, `logo_url`), `has_more` and `next_cursor` out. Read tolerantly all the same: the list under any of
// a few keys, a voice without an ID left out.

/// One voice `voice_change` can take.
public struct Voice: Sendable, Hashable {
    public var id: String
    /// "preset" or "element", sent back with the ID as it came.
    public var type: String
    public var name: String
    /// An https sample; `nil` when the answer names none.
    public var previewURL: URL?

    public init(id: String, type: String, name: String, previewURL: URL? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.previewURL = previewURL
    }
}

/// One page of voices, in the server's order.
public struct VoicePage: Sendable, Hashable {
    public var items: [Voice]
    /// Opaque: sent back unchanged for the next page. `nil` on the last page.
    public var nextCursor: JSONValue?

    public init(items: [Voice], nextCursor: JSONValue?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

extension VoicePage {
    static let listKeys = ["voices", ToolKey.items, ToolKey.data, ToolKey.results]

    /// `nil` when no list is found.
    init?(_ value: JSONValue) {
        guard let items = Self.listKeys.lazy.compactMap({ value[$0]?.arrayValue }).first ?? value.arrayValue else {
            return nil
        }
        self.items = items.compactMap(Voice.init)
        let cursor = value[ToolKey.nextCursor] ?? value["nextCursor"]
        // A last page may still carry a cursor; `has_more` says it is the last.
        nextCursor = cursor == .null || value["has_more"] == false ? nil : cursor
    }
}

extension Voice {
    static let idKeys = [ToolKey.voiceID, "voiceId", ToolKey.id]
    static let typeKeys = [ToolKey.voiceType, "voiceType", ToolKey.type]
    static let previewKeys = [ToolKey.previewURL, "previewUrl", "sample_url", "audio_url"]
    /// What a voice is when the answer doesn't say: the built-in kind.
    static let defaultType = "preset"

    init?(_ value: JSONValue) {
        guard let id = Self.idKeys.lazy.compactMap({ value[$0]?.stringValue }).first, !id.isEmpty else { return nil }
        let name = AccountImageModel.nameKeys.lazy.compactMap { value[$0]?.stringValue }.first
        self.init(
            id: id, type: Self.typeKeys.lazy.compactMap { value[$0]?.stringValue }.first ?? Self.defaultType,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
            previewURL: Self.previewKeys.lazy.compactMap { value[$0]?.stringValue.flatMap(URL.init(serverMedia:)) }
                .first)
    }
}

extension HiggsfieldAccount {
    /// A page of the voices `voice_change` takes: built-in ones and the account's own.
    /// - Parameters:
    ///   - cursor: `nextCursor` of the page before, as it came.
    ///   - size: 1–100.
    public func voices(cursor: JSONValue? = nil, size: Int = 100) async throws -> VoicePage {
        var arguments: [String: JSONValue] = [ToolKey.size: .number(Double(min(max(size, 1), 100)))]
        if let cursor, cursor != .null { arguments[ToolKey.cursor] = cursor }
        guard let page = VoicePage(try await call(.listVoices, arguments)) else {
            throw HiggsfieldError.validation(field: nil, message: "Unexpected result from the list_voices tool")
        }
        return page
    }
}
