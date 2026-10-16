import Foundation

/// A JSON array of records decoded one by one: a record that can't be read, such as one written by a newer version,
/// is skipped instead of failing the whole list, and counted so the file holding it can be kept aside before it is
/// written over.
public struct RecordList<Record: Decodable>: Decodable {
    public var records: [Record] = []
    /// How many records couldn't be read.
    public var skipped = 0

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let record = try? container.decode(Record.self) {
                records.append(record)
            } else {
                skipped += 1
                // Steps past the record that couldn't be read.
                _ = try container.decode(Skipped.self)
            }
        }
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

extension RecordList {
    /// Where a file that couldn't be read in full is kept: next to it, under a name of its own, so a later write
    /// never replaces records it couldn't read.
    public static func asideURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).unreadable-\(UUID())")
    }
}
