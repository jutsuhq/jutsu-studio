import Foundation

/// Remembers uploads by content hash so the same input isn't uploaded twice.
public protocol UploadCache: Sendable {
    /// The asset uploaded for `contentHash` at or after `date`, if any.
    func asset(forContentHash contentHash: String, uploadedAfter date: Date) async throws -> RemoteAsset?
    func store(_ asset: RemoteAsset, contentHash: String, uploadedAt: Date) async throws
    /// Forgets the assets uploaded before `date`.
    func removeAssets(uploadedBefore date: Date) async throws
}
