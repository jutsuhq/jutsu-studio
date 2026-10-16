import Foundation
import JutsuCore

/// "Save to Higgsfield…" on a batch character; `nil` without an account connection that publishes elements.
public struct CharacterSaving {
    /// The signed-in account, which a set's saved element must belong to.
    public let owner: String?
    /// Publishes the set under the name and records it on the form; returns why it failed.
    public let save: @MainActor (_ images: [LocalImage], _ name: String) async -> UserMessage?

    init(
        owner: String?, save: @escaping @MainActor (_ images: [LocalImage], _ name: String) async -> UserMessage?
    ) {
        self.owner = owner
        self.save = save
    }

    /// Publishes a set through `elements`, uploading its images with `upload`, and hands the saved element to
    /// `record`. `nil` when `elements` can't publish or there is no `upload` (disconnected).
    /// - Parameter owner: the signed-in account.
    @MainActor
    public init?(
        elements: AccountElementsModel?, owner: String?,
        upload: (@Sendable (LocalImage) async throws -> RemoteAsset)?,
        record: @escaping @MainActor (_ element: SavedElement, _ images: [LocalImage]) -> Void
    ) {
        guard let elements, elements.canPublish, let upload else { return nil }
        self.init(owner: owner) { images, name in
            do {
                let saved = try await elements.publish(images, name: name, upload: upload)
                record(saved, images)
                return nil
            } catch {
                return SavedElement.failure(error)
            }
        }
    }
}
