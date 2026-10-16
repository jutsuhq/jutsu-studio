import Foundation
import SwiftData

public enum StoreContainer {
    /// The current development schema. Unreleased stores have no compatibility contract.
    public static var schema: Schema {
        Schema([
            JobRecord.self, MaterialRecord.self, AssetRecord.self, TemplateRecord.self, StarredPromptRecord.self,
            DeliverySetRecord.self,
        ])
    }

    /// The app's container: `default.store` under `layout.root`, or memory only for tests and previews.
    public static func make(inMemory: Bool, layout: FileLayout = FileLayout()) throws -> ModelContainer {
        let schema = Self.schema
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            try layout.prepareDirectories()
            configuration = ModelConfiguration(schema: schema, url: layout.storeURL, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
