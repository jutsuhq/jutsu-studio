import Foundation
import HiggsfieldMCP
import JutsuCore

/// Maps the account's completed reference elements to reusable image inputs.
enum AccountElementsMapping {
    /// Whether the element can be used: only a `completed` one ("skip processing / ip_checking / failed /
    /// kling_failed / nsfw", says the tool). No state reads as usable.
    static func isUsable(_ element: ReferenceElement) -> Bool {
        element.status.map { $0 == "completed" } ?? true
    }

    /// - Parameter listed: from a list page, which names only an element's first image: it is kept as the
    ///   thumbnail and the images are left out, so picking the element asks `get` for all of them.
    static func element(_ element: ReferenceElement, owner: String?, listed: Bool = false) -> AccountElement {
        AccountElement(
            id: element.id, name: element.name,
            category: element.category.flatMap { ElementCategory(rawValue: $0.rawValue) },
            thumbnailURL: element.thumbnailURL,
            images: listed
                ? []
                : element.images.map { image in
                    JutsuCore.ElementImage(
                        url: image.url, media: image.mediaID.map { ServerMedia(id: $0, url: image.url, owner: owner) })
                })
    }
}

extension HiggsfieldMCPProvider: AccountElements {
    public static var offersReferenceElements: Bool { true }

    public func elements(after cursor: HistoryCursor?) async throws -> AccountElementPage {
        let page = try await mapped {
            try await account.referenceElements(
                cursor: cursor.flatMap(HistoryMapping.cursorValue), size: Self.elementPageSize)
        }
        // An empty page that still names a next one would never end.
        let next = page.items.isEmpty ? nil : page.nextCursor.flatMap(HistoryMapping.cursor)
        return AccountElementPage(
            items: page.items.filter(AccountElementsMapping.isUsable).map {
                AccountElementsMapping.element($0, owner: owner, listed: true)
            },
            nextCursor: next)
    }

    /// `get` of an element, for all its images.
    public func elementImages(_ element: AccountElement) async throws -> AccountElement {
        let full = try await mapped { try await account.referenceElement(id: element.id) }
        return AccountElementsMapping.element(full, owner: owner)
    }

    /// `show_reference_elements` `create` with the uploads as `media_input`. An upload without a media ID, or not on
    /// https (the tool rejects other URLs), is refused before anything is sent.
    public func createElement(
        name: String, category: ElementCategory, images: [RemoteAsset]
    ) async throws -> AccountElement {
        let uploads = try images.map { asset in
            guard let id = asset.id, asset.url.isHTTPS else {
                throw ProviderError.validation(
                    field: nil,
                    message: String(localized: "Unexpected result from the media_upload tool", bundle: .module))
            }
            return UploadedMedia(id: id, url: asset.url)
        }
        guard !uploads.isEmpty else {
            throw ProviderError.validation(
                field: nil, message: String(localized: "An element needs at least one image.", bundle: .module))
        }
        let created = try await mapped {
            try await account.createReferenceElement(
                name: name, category: ReferenceElement.Category(rawValue: category.rawValue), images: uploads)
        }
        return AccountElementsMapping.element(created, owner: owner)
    }

    /// Reuses an element's media ID or a character sheet's job ID only for the account that listed it.
    public func serverAsset(_ media: ServerMedia) async throws -> RemoteAsset? {
        guard media.owner == owner else { return nil }
        return RemoteAsset(url: media.url, id: media.id)
    }

    static let elementPageSize = 30
}
