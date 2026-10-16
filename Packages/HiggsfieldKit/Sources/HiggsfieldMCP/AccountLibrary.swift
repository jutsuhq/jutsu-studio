import Foundation

// Read from the live server on 2026-10-14 with `transactions` and `assets_picker_list` (uploads of each kind);
// `set_generation_like` from its `inputSchema` only. A transaction names no job, only its tool and time.

/// One movement of the account's credits.
public struct CreditTransaction: Sendable, Hashable {
    public var date: Date
    /// Negative when spent, positive when refunded or granted.
    public var credits: Double
    /// "spend", "refund", "grant" or "deduct".
    public var action: String
    /// What it was for, as Higgsfield names it: "Higgsfield Genjutsu - Object Swap".
    public var title: String

    public init(date: Date, credits: Double, action: String, title: String) {
        self.date = date
        self.credits = credits
        self.action = action
        self.title = title
    }
}

/// One page of the account's credit history, newest first.
public struct CreditTransactionPage: Sendable, Hashable {
    public var items: [CreditTransaction]
    /// Opaque: sent back unchanged for the next page. `nil` on the last page.
    public var nextCursor: JSONValue?

    public init(items: [CreditTransaction], nextCursor: JSONValue?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// The `kind` filter of the account's uploads.
public enum AssetKind: String, Sendable, CaseIterable {
    case image
    case video
}

/// A file the account uploaded, as a generation input or on higgsfield.ai.
public struct AccountAsset: Sendable, Hashable {
    /// The `media_id` generations take.
    public var id: String
    public var kind: AssetKind
    public var url: URL
    /// Videos only.
    public var thumbnailURL: URL?
    public var width: Int?
    public var height: Int?
    /// Videos only, in seconds.
    public var duration: Double?
    public var createdAt: Date

    public init(
        id: String, kind: AssetKind, url: URL, thumbnailURL: URL? = nil, width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.height = height
        self.duration = duration
        self.createdAt = createdAt
    }
}

/// One page of the account's uploads, newest first.
public struct AccountAssetPage: Sendable, Hashable {
    public var items: [AccountAsset]
    /// Opaque: sent back unchanged for the next page. `nil` on the last page.
    public var nextCursor: JSONValue?

    public init(items: [AccountAsset], nextCursor: JSONValue?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

extension CreditTransactionPage {
    /// `nil` when there is no `items` array. Items without a time or amount are left out.
    init?(_ value: JSONValue) {
        guard let items = value[ToolKey.items]?.arrayValue else { return nil }
        self.items = items.compactMap(CreditTransaction.init)
        let cursor = value[ToolKey.nextCursor]
        nextCursor = cursor == .null ? nil : cursor
    }
}

extension CreditTransaction {
    init?(_ value: JSONValue) {
        guard let date = value[ToolKey.createdAtSnake]?.stringValue.flatMap(Self.date(iso:)),
            let credits = value[ToolKey.credits]?.numberValue
        else { return nil }
        self.init(
            date: date, credits: credits, action: value[ToolKey.action]?.stringValue ?? "",
            title: value[ToolKey.displayName]?.stringValue ?? "")
    }

    /// "2026-10-14T12:33:58.452235Z": microseconds, which `ISO8601DateFormatter` doesn't read on every platform,
    /// so the fraction is parsed apart.
    static func date(iso text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: "."),
            let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        {
            fraction = Double("0" + text[dot..<zone]) ?? 0
            whole = String(text[..<dot] + text[zone...])
        }
        return ISO8601DateFormatter().date(from: whole).map { $0.addingTimeInterval(fraction) }
    }
}

extension AccountAssetPage {
    /// `nil` when there is no `items` array. Items without an ID, kind or URL are left out.
    init?(_ value: JSONValue) {
        guard let items = value[ToolKey.items]?.arrayValue else { return nil }
        self.items = items.compactMap(AccountAsset.init)
        let cursor = value[ToolKey.nextCursor]
        nextCursor = cursor == .null ? nil : cursor
    }
}

extension AccountAsset {
    init?(_ value: JSONValue) {
        guard let id = value[ToolKey.id]?.stringValue,
            let kind = value[ToolKey.kind]?.stringValue.flatMap(AssetKind.init(rawValue:)),
            let url = value[ToolKey.url]?.stringValue.flatMap(URL.init(serverMedia:))
        else { return nil }
        self.init(
            id: id, kind: kind, url: url,
            thumbnailURL: value[ToolKey.thumbnailURLCamel]?.stringValue.flatMap(URL.init(serverMedia:)),
            width: value[ToolKey.width]?.numberValue.flatMap(ModelLimits.count),
            height: value[ToolKey.height]?.numberValue.flatMap(ModelLimits.count),
            duration: value[ToolKey.duration]?.numberValue,
            // Unix seconds with a fraction.
            createdAt: Date(timeIntervalSince1970: value[ToolKey.createdAt]?.numberValue ?? 0))
    }
}
