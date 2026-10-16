import Foundation
import JutsuCore

/// What views make of stored jobs, by record id, so a render decodes only records that are new or whose stored job
/// changed. Records missing from a call are forgotten, so deleted results don't linger.
public final class DecodedJobCache<Item> {
    private struct Entry {
        var data: Data
        /// `nil` when the record doesn't decode; kept so a broken record isn't decoded on every render.
        var item: Item?
    }

    private let makeItem: (Job) -> Item
    private var entries: [UUID: Entry] = [:]

    public init(_ makeItem: @escaping (Job) -> Item) {
        self.makeItem = makeItem
    }

    /// Items for `records` in their order, skipping records that don't decode.
    /// - Parameters:
    ///   - data: the stored job; a record is decoded again only when this changes.
    ///   - job: decodes a record.
    public func items<Record>(
        for records: [Record], id: (Record) -> UUID, data: (Record) -> Data, job: (Record) throws -> Job
    ) -> [Item] {
        var next: [UUID: Entry] = [:]
        next.reserveCapacity(records.count)
        var items: [Item] = []
        items.reserveCapacity(records.count)
        for record in records {
            let key = id(record)
            let stored = data(record)
            let entry: Entry
            if let cached = entries[key], cached.data == stored {
                entry = cached
            } else {
                entry = Entry(data: stored, item: (try? job(record)).map(makeItem))
            }
            next[key] = entry
            if let item = entry.item { items.append(item) }
        }
        entries = next
        return items
    }
}

extension DecodedJobCache where Item == Job {
    /// Keeps the jobs as they are.
    public convenience init() {
        self.init { $0 }
    }
}
