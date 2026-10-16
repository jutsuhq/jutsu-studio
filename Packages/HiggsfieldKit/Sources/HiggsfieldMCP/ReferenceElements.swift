import Foundation
import HiggsfieldCore

// `show_reference_elements` as the catalog snapshot of 2026-10-15 states it (`docs/mcp-snapshots/2026-10-15.json`). Elements: `action` `list` (`size` 1–100, `cursor` a number from the last
// page's `next_cursor`) or `get` (`element_id`); both answer `{items, next_cursor}`, `get` with the one element.
// `create` takes `name` (at most 32 characters), `category` and `medias: [{id, url, type}]` of confirmed uploads, and
// answers synchronously with the new element under `element`. Nothing in the tool names a price or a credit argument.
// Each element has `id`, `name`, `category`, `status` and `medias: [{id, url, type}]`, where `type` `media_input`
// is an upload's `media_id` and `image_job` a finished image job's ID, both of which `generate_video` takes as a
// `medias[].value`. A list item names only its first image. An element is used by these image IDs, never by its own
// ID: the tool says element IDs don't go into `params.medias`.

/// A named character, environment or prop the account keeps (`show_reference_elements`).
public struct ReferenceElement: Sendable, Hashable {
    /// What a reference element shows.
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case character
        case environment
        case prop
    }

    /// One image of a reference element.
    public struct Image: Sendable, Hashable {
        public var url: URL
        /// The `media_id` or image job ID generations take; `nil` when the answer names none.
        public var mediaID: String?

        public init(url: URL, mediaID: String? = nil) {
            self.url = url
            self.mediaID = mediaID
        }
    }

    public var id: String
    public var name: String
    /// `nil` when the answer names none.
    public var category: Category?
    public var thumbnailURL: URL?
    /// An element's images: only the first one in a list, all of them from `get`.
    public var images: [Image]
    /// The state as the server names it: `completed`, `processing`, `ip_checking`, `failed`, `nsfw` or
    /// `kling_failed`.
    public var status: String?

    public init(
        id: String, name: String, category: Category? = nil, thumbnailURL: URL? = nil,
        images: [Image] = [], status: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.thumbnailURL = thumbnailURL
        self.images = images
        self.status = status
    }
}

/// One page of elements, in the server's order.
public struct ReferenceElementPage: Sendable, Hashable {
    public var items: [ReferenceElement]
    /// Opaque: sent back unchanged for the next page. `nil` on the last page.
    public var nextCursor: JSONValue?

    public init(items: [ReferenceElement], nextCursor: JSONValue?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

extension ReferenceElementPage {
    /// `nil` when the answer has no `items`. Items without an ID are left out.
    init?(_ value: JSONValue) {
        guard let items = value[ToolKey.items]?.arrayValue else { return nil }
        self.items = items.compactMap(ReferenceElement.init)
        let cursor = value[ToolKey.nextCursor]
        nextCursor = cursor == .null ? nil : cursor
    }
}

extension ReferenceElement {
    /// Previews an answer may name, best first; else the first image.
    static let thumbnailKeys = [ToolKey.thumbnailURL, ToolKey.previewURL, ToolKey.url]
    /// The suffix of a category the server verified for protected content (`character_ip_verified`).
    static let verifiedSuffix = "_ip_verified"

    init?(_ value: JSONValue) {
        guard let id = value[ToolKey.id]?.stringValue, !id.isEmpty else { return nil }
        let images = (value[ToolKey.medias]?.arrayValue ?? []).compactMap(Image.init)
        let thumbnail = Self.thumbnailKeys.lazy.compactMap { value[$0]?.stringValue.flatMap(URL.init(serverMedia:)) }
            .first
        let category = value[ToolKey.category]?.stringValue.map { name in
            name.hasSuffix(Self.verifiedSuffix) ? String(name.dropLast(Self.verifiedSuffix.count)) : name
        }
        self.init(
            id: id, name: value[ToolKey.name]?.stringValue ?? "", category: category.flatMap(Category.init),
            thumbnailURL: thumbnail ?? images.first?.url, images: images,
            status: value[ToolKey.status]?.stringValue)
    }
}

extension ReferenceElement.Image {
    /// `{id, url, type}` with an https URL.
    init?(_ value: JSONValue) {
        guard let url = value[ToolKey.url]?.stringValue.flatMap(URL.init(serverMedia:)) else { return nil }
        self.init(url: url, mediaID: value[ToolKey.id]?.stringValue)
    }
}

extension HiggsfieldAccount {
    /// A page of the account's reference elements of the selected workspace, newest first.
    /// - Parameters:
    ///   - cursor: `nextCursor` of the page before, as it came.
    ///   - size: 1–100.
    public func referenceElements(cursor: JSONValue? = nil, size: Int = 30) async throws -> ReferenceElementPage {
        try await elementPage(.referenceElements, cursor: cursor, size: size)
    }

    /// One element with all its images (`get`).
    public func referenceElement(id: String) async throws -> ReferenceElement {
        let value = try await call(
            .referenceElements, [ToolKey.action: .string(ToolKey.get), ToolKey.elementID: .string(id)])
        guard let element = ReferenceElementPage(value)?.items.first else {
            throw HiggsfieldError.validation(
                field: nil,
                message: value[ToolKey.error]?.stringValue
                    ?? "Unexpected result from the show_reference_elements tool")
        }
        return element
    }

    /// `create`: a new element from confirmed uploads (`upload(fileAt:contentType:)`), each sent as `media_input`.
    /// Not idempotent: sent again, it makes a second element.
    /// - Parameters:
    ///   - name: cut to `nameLimit` characters; `nil` or empty lets the server derive one from the images.
    ///   - category: `nil` lets the server classify the element (`auto`).
    public func createReferenceElement(
        name: String?, category: ReferenceElement.Category?, images: [UploadedMedia]
    ) async throws -> ReferenceElement {
        // `list` and `get` work without `create`'s arguments, so the role alone doesn't say the tool creates.
        guard let tool = try await lookUp(.referenceElements, recheckingAfter: 0),
            tool.argumentNames.contains(ToolKey.medias)
        else { throw HiggsfieldError.toolUnavailable(ToolRole.referenceElements.rawValue) }
        var arguments: [String: JSONValue] = [
            ToolKey.action: .string(ToolKey.create),
            ToolKey.category: .string(category?.rawValue ?? ToolKey.auto),
            ToolKey.medias: .array(
                images.map {
                    [
                        ToolKey.id: .string($0.id), ToolKey.url: .string($0.url.absoluteString),
                        ToolKey.type: .string(ToolKey.mediaInput),
                    ]
                }),
        ]
        let name = name.map { trimmed in
            String(trimmed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.elementNameLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name, !name.isEmpty { arguments[ToolKey.name] = .string(name) }
        let value = try await call(.referenceElements, arguments)
        guard let element = value[ToolKey.element].flatMap(ReferenceElement.init) else {
            throw failure(value, role: .referenceElements)
        }
        return element
    }

    /// `create`'s `name`: "max 32 chars".
    public static let elementNameLimit = 32

    private func elementPage(_ role: ToolRole, cursor: JSONValue?, size: Int) async throws -> ReferenceElementPage {
        var arguments: [String: JSONValue] = [
            ToolKey.action: .string(ToolKey.list), ToolKey.size: .number(Double(min(max(size, 1), 100))),
        ]
        if let cursor, cursor != .null { arguments[ToolKey.cursor] = cursor }
        let value = try await call(role, arguments)
        guard let page = ReferenceElementPage(value) else {
            throw HiggsfieldError.validation(
                field: nil,
                message: value[ToolKey.error]?.stringValue ?? "Unexpected result from the \(role.rawValue) tool")
        }
        return page
    }
}
