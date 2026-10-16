import Foundation
import JutsuCore
import SwiftData

/// A persisted `DeliverySet`, stored as JSON in `setData` like `TemplateRecord`; `name` and `createdAt` are copies
/// for sorting. Its items are `MaterialReference`s to exact catalog versions, never copies of the files.
@Model
public final class DeliverySetRecord {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var name: String
    public private(set) var createdAt: Date
    public private(set) var setData: Data

    public init(_ set: DeliverySet) throws {
        id = set.id
        name = set.name
        createdAt = set.createdAt
        setData = try JSONEncoder().encode(set)
    }

    public func deliverySet() throws -> DeliverySet {
        let set = try JSONDecoder().decode(DeliverySet.self, from: setData)
        guard set.id == id else { throw MaterialError.invalidRecord }
        return set
    }

    /// Writes `set` over the stored one. Once the stored set is frozen its versions can't change and it can't be
    /// unfrozen: either throws `DeliverySetError.frozen` and leaves the record as it was.
    public func update(_ set: DeliverySet) throws {
        guard set.id == id else { throw MaterialError.invalidRecord }
        let stored = try deliverySet()
        if stored.isFrozen {
            guard set.isFrozen, set.items.map(\.reference) == stored.items.map(\.reference) else {
                throw DeliverySetError.frozen
            }
        }
        setData = try JSONEncoder().encode(set)
        name = set.name
        createdAt = set.createdAt
    }

    /// Every set, newest first.
    public static var newestFirst: FetchDescriptor<DeliverySetRecord> {
        FetchDescriptor<DeliverySetRecord>(sortBy: [SortDescriptor(\DeliverySetRecord.createdAt, order: .reverse)])
    }

    /// Saves `set` in `context`: a new record, or an update of its own under the freezing rule of `update`.
    public static func save(_ set: DeliverySet, in context: ModelContext) throws {
        do {
            let id = set.id
            var descriptor = FetchDescriptor<DeliverySetRecord>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                try existing.update(set)
            } else {
                context.insert(try DeliverySetRecord(set))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
