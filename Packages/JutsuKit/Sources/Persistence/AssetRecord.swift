import Foundation
import JutsuCore
import SwiftData

/// An uploaded input, remembered by the SHA-256 of its prepared file so it isn't uploaded twice.
@Model
public final class AssetRecord {
    @Attribute(.unique) public private(set) var contentHash: String
    public private(set) var remoteURL: URL
    /// `RemoteAsset.id`; `nil` for records from before it was kept.
    public private(set) var remoteID: String?
    public private(set) var uploadedAt: Date

    public init(contentHash: String, asset: RemoteAsset, uploadedAt: Date) {
        self.contentHash = contentHash
        self.remoteURL = asset.url
        self.remoteID = asset.id
        self.uploadedAt = uploadedAt
    }

    public var asset: RemoteAsset { RemoteAsset(url: remoteURL, id: remoteID) }

    public func update(_ asset: RemoteAsset, uploadedAt: Date) {
        self.remoteURL = asset.url
        self.remoteID = asset.id
        self.uploadedAt = uploadedAt
    }
}
