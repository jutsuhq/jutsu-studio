import Foundation
import JutsuCore
import Persistence
import SwiftData
import Testing

@Suite struct StarredPromptRecordTests {
    @Test func starsAreUniqueByTextAndNewestFirst() throws {
        let context = ModelContext(try StoreContainer.make(inMemory: true))
        context.insert(StarredPromptRecord(text: "clay", starredAt: Date(timeIntervalSince1970: 1)))
        context.insert(StarredPromptRecord(text: "neon", starredAt: Date(timeIntervalSince1970: 2)))
        try context.save()
        #expect(try context.fetch(StarredPromptRecord.newestFirst).map(\.text) == ["neon", "clay"])
    }

    @Test func promptHistoryFetchSkipsEmptyPromptsAndClearedJobs() throws {
        let context = ModelContext(try StoreContainer.make(inMemory: true))
        let old = makeJob(createdAt: Date(timeIntervalSince1970: 10))
        let new = makeJob(createdAt: Date(timeIntervalSince1970: 30))
        var empty = makeJob(createdAt: Date(timeIntervalSince1970: 40))
        empty.spec.prompt = ""
        for job in [old, new, empty] { context.insert(try JobRecord(job: job)) }
        try context.save()

        #expect(try context.fetch(JobRecord.withPrompts(after: nil)).map(\.id) == [new.id, old.id])
        #expect(try context.fetch(JobRecord.withPrompts(after: Date(timeIntervalSince1970: 20))).map(\.id) == [new.id])
    }
}
