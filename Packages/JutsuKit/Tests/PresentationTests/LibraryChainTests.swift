import Foundation
import JutsuCore
import Testing

@testable import Presentation

@Suite struct LibraryChainTests {
    private func item(
        _ resolution: Resolution, isDraft: Bool = false, parent: LibraryItemModel? = nil, parentID: UUID? = nil,
        minutes: Double
    ) -> LibraryItemModel {
        var item = LibraryFixture.item(resolution: resolution, isDraft: isDraft)
        item.job = Job(
            spec: item.spec, providerKind: .apiKey, parentID: parent?.id ?? parentID, cost: item.job.cost,
            createdAt: LibraryFixture.now.addingTimeInterval(minutes * 60))
        return item
    }

    private func titles(_ chain: LibraryChain) -> [String] { chain.steps.map(\.title) }

    @Test func aFinalShowsTheDraftItCameFromAndItsSiblingsInOrder() {
        let draft = item(.p480, isDraft: true, minutes: 0)
        let final720 = item(.p720, parent: draft, minutes: 1)
        let final1080 = item(.p1080, parent: draft, minutes: 2)
        let unrelated = item(.p720, minutes: 3)
        let library = [unrelated, final1080, final720, draft]

        let chain = LibraryChain(for: final1080.id, in: library)

        #expect(titles(chain) == ["draft 480p", "final 720p", "final 1080p"])
        #expect(chain.steps.map(\.id) == [draft.id, final720.id, final1080.id])
        #expect(chain.steps.map(\.isCurrent) == [false, false, true])
        #expect(LibraryChain(for: draft.id, in: library).steps.map(\.id) == chain.steps.map(\.id))
    }

    @Test func aRerunOfAFinalExtendsTheChain() {
        let draft = item(.p480, isDraft: true, minutes: 0)
        let final = item(.p720, parent: draft, minutes: 1)
        let rerun = item(.p1080, parent: final, minutes: 2)

        let chain = LibraryChain(for: draft.id, in: [rerun, final, draft])

        #expect(titles(chain) == ["draft 480p", "final 720p", "final 1080p"])
        #expect(chain.steps.first?.isCurrent == true)
    }

    @Test func aDeletedParentStaysAsADeletedStepAndKeepsItsChildren() {
        let deleted = UUID()
        let final720 = item(.p720, parentID: deleted, minutes: 1)
        let final1080 = item(.p1080, parentID: deleted, minutes: 2)

        let chain = LibraryChain(for: final720.id, in: [final1080, final720])

        #expect(titles(chain) == ["deleted", "final 720p", "final 1080p"])
        #expect(chain.steps.map(\.isDeleted) == [true, false, false])
        #expect(chain.steps.first?.id == deleted)
    }

    @Test func anItemWithoutParentOrChildrenHasNoChain() {
        let alone = item(.p720, minutes: 0)
        #expect(LibraryChain(for: alone.id, in: [alone]).isEmpty)
        #expect(LibraryChain(for: UUID(), in: [alone]).steps.isEmpty)
    }

    @Test func aParentCycleStillEnds() {
        let firstID = UUID()
        var first = item(.p480, isDraft: true, minutes: 0)
        var second = item(.p720, minutes: 1)
        first.job = Job(
            id: firstID, spec: first.spec, providerKind: .apiKey, parentID: second.id, cost: first.job.cost,
            createdAt: first.job.createdAt)
        second.job.parentID = firstID

        #expect(LibraryChain(for: second.id, in: [first, second]).steps.count == 2)
    }
}

@Suite struct LibraryStarredFilterTests {
    @Test func starredFilterKeepsOnlyStarredItemsAndCombinesWithTheOthers() {
        var starredDraft = LibraryFixture.item(isDraft: true)
        starredDraft.isStarred = true
        var starredFinal = LibraryFixture.item(resolution: .p1080, isDraft: false)
        starredFinal.isStarred = true
        let plain = LibraryFixture.item(isDraft: false)
        let items = [starredDraft, plain, starredFinal]

        #expect(LibraryFilter(isStarredOnly: true).apply(items) == [starredDraft, starredFinal])
        #expect(LibraryFilter(finish: .finals, isStarredOnly: true).apply(items) == [starredFinal])
        #expect(LibraryFilter(isStarredOnly: true).isActive)
        #expect(LibraryFilter().apply(items) == items)
    }
}
