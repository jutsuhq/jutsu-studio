import Foundation
import JutsuCore
import Testing

@testable import Presentation

struct DecodedJobCacheTests {
    /// Stands in for a stored record: an id and the job encoded as JSON.
    private struct Record {
        var id: UUID
        var data: Data

        init(_ job: Job) throws {
            id = job.id
            data = try JSONEncoder().encode(job)
        }
    }

    /// Counts decodes so a test sees which records were decoded again.
    private final class Decoder {
        var count = 0

        func items(_ cache: DecodedJobCache<Job>, _ records: [Record]) -> [Job] {
            cache.items(for: records, id: \.id, data: \.data) { record in
                count += 1
                return try JSONDecoder().decode(Job.self, from: record.data)
            }
        }
    }

    @Test func unchangedRecordsAreNotDecodedAgain() throws {
        let cache = DecodedJobCache<Job>()
        let decoder = Decoder()
        let records = try [Record(LibraryFixture.item().job), Record(LibraryFixture.item(source: "b.mov").job)]

        let first = decoder.items(cache, records)
        let second = decoder.items(cache, records)

        #expect(decoder.count == 2)
        #expect(first.map(\.id) == records.map(\.id))
        #expect(second == first)
    }

    @Test func newRecordsAreDecodedInTheirOrder() throws {
        let cache = DecodedJobCache<Job>()
        let decoder = Decoder()
        let old = try Record(LibraryFixture.item().job)
        _ = decoder.items(cache, [old])

        let new = try Record(LibraryFixture.item(source: "new.mov").job)
        let items = decoder.items(cache, [new, old])

        #expect(decoder.count == 2)
        #expect(items.map(\.id) == [new.id, old.id])
    }

    @Test func anEditedRecordIsDecodedAgain() throws {
        let cache = DecodedJobCache<Job>()
        let decoder = Decoder()
        var job = LibraryFixture.item(prompt: "before").job
        let other = try Record(LibraryFixture.item(source: "b.mov").job)
        _ = try decoder.items(cache, [Record(job), other])

        job.spec.prompt = "after"
        let items = try decoder.items(cache, [Record(job), other])

        #expect(decoder.count == 3)
        #expect(items.first?.spec.prompt == "after")
    }

    @Test func aDeletedRecordIsForgotten() throws {
        let cache = DecodedJobCache<Job>()
        let decoder = Decoder()
        let kept = try Record(LibraryFixture.item().job)
        let deleted = try Record(LibraryFixture.item(source: "b.mov").job)
        _ = decoder.items(cache, [kept, deleted])

        #expect(decoder.items(cache, [kept]).map(\.id) == [kept.id])
        // Back again (undo): decoded anew, not served from a stale entry.
        #expect(decoder.items(cache, [kept, deleted]).map(\.id) == [kept.id, deleted.id])
        #expect(decoder.count == 3)
    }

    @Test func aRecordThatDoesNotDecodeIsSkippedAndNotRetriedUntilItChanges() throws {
        let cache = DecodedJobCache<Job>()
        let decoder = Decoder()
        let good = try Record(LibraryFixture.item().job)
        var broken = good
        broken.id = UUID()
        broken.data = Data("{}".utf8)

        #expect(decoder.items(cache, [broken, good]).map(\.id) == [good.id])
        #expect(decoder.items(cache, [broken, good]).map(\.id) == [good.id])
        #expect(decoder.count == 2)
    }
}
