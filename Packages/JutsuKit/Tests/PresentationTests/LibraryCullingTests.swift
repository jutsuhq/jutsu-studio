import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Catalog entries as the store holds them, turned into grid rows the way the Library does.
enum CatalogFixture {
    static let now = LibraryFixture.now

    static func video(
        prompt: String = "", group: UUID? = nil, batch: UUID? = nil, minutesAgo: Double = 10,
        culling: Culling = .unreviewed, isPrimary: Bool = false
    ) -> Material {
        var job = LibraryFixture.item(prompt: prompt, minutesAgo: minutesAgo).job
        job.batchID = batch
        job.variantGroupID = group
        var version = MaterialVersion(
            id: job.id, createdAt: job.finishedAt ?? now, fileURL: job.outputFile,
            generation: MaterialGeneration(prompt: prompt, model: job.spec.model.rawValue), video: job)
        version.culling = culling
        var material = Material(
            id: job.id, kind: .video, createdAt: job.createdAt, variantGroupID: group, version: version)
        material.isVariantPrimary = isPrimary
        return material
    }

    static func image(
        prompt: String = "A knight", group: UUID? = nil, minutesAgo: Double = 10, culling: Culling = .unreviewed,
        isPrimary: Bool = false
    ) -> Material {
        var version = MaterialVersion(
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID()).png"),
            generation: MaterialGeneration(prompt: prompt, model: "soul"))
        version.culling = culling
        var material = Material(
            kind: .image, createdAt: now.addingTimeInterval(-minutesAgo * 60), variantGroupID: group,
            version: version)
        material.isVariantPrimary = isPrimary
        return material
    }

    static func rows(_ materials: [Material]) -> [LibraryMediaItem] {
        materials.compactMap(MaterialLibrary.row)
    }
}

@Suite struct CullingHistoryTests {
    let materials = [CatalogFixture.image(), CatalogFixture.image(culling: .kept), CatalogFixture.video()]
    var index: LibraryCatalogIndex { LibraryCatalogIndex(materials) }
    var ids: [UUID] { materials.map(\.id) }

    @Test func eachActionSetsItsState() {
        #expect(CullingAction.keep.result == .kept)
        #expect(CullingAction.reject.result == .rejected)
        #expect(CullingAction.clear.result == .unreviewed)
    }

    @Test func applyingWritesOnlyTheVersionsThatChange() {
        var history = CullingHistory()
        let writes = history.apply(.keep, to: ids, in: index)
        #expect(writes == [materials[0].reference: .kept, materials[2].reference: .kept])
        #expect(history.steps.count == 1)
        // Keeping what is kept already changes nothing and takes no Undo of its own.
        let again = history.apply(.keep, to: [ids[1]], in: index)
        let unknown = history.apply(.keep, to: [UUID()], in: index)
        #expect(again == nil && unknown == nil)
        #expect(history.steps.count == 1)
    }

    @Test func undoRestoresTheLastChangeFirst() {
        var history = CullingHistory()
        _ = history.apply(.reject, to: [ids[0]], in: index)
        _ = history.apply(.clear, to: [ids[1]], in: index)
        let last = history.undo()
        let first = history.undo()
        let none = history.undo()
        #expect(last == [materials[1].reference: .kept])
        #expect(first == [materials[0].reference: .unreviewed])
        #expect(none == nil)
        #expect(!history.canUndo)
    }

    @Test func theStackKeepsTheNewestSteps() {
        var history = CullingHistory()
        for step in 0..<(CullingHistory.limit + 5) {
            let action: CullingAction = step.isMultiple(of: 2) ? .reject : .keep
            let current = LibraryCatalogIndex([CatalogFixture.image(culling: action == .keep ? .rejected : .kept)])
            _ = history.apply(action, to: Array(current.entries.keys), in: current)
        }
        #expect(history.steps.count == CullingHistory.limit)
    }

    @Test func aKeyPressPicksTheActionItIsAssigned() {
        let assigned = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        #expect(CullingAction.pressed(Shortcut(key: .character("p"), modifiers: []), assigned: assigned) == .keep)
        #expect(CullingAction.pressed(Shortcut(key: .character("x"), modifiers: []), assigned: assigned) == .reject)
        #expect(CullingAction.pressed(Shortcut(key: .character("u"), modifiers: []), assigned: assigned) == .clear)
        #expect(CullingAction.pressed(Shortcut(key: .character("p"), modifiers: .command), assigned: assigned) == nil)
        var custom = assigned
        custom[.keep] = Shortcut(key: .character("k"), modifiers: [])
        #expect(CullingAction.pressed(Shortcut(key: .character("p"), modifiers: []), assigned: custom) == nil)
        #expect(CullingAction.pressed(Shortcut(key: .character("k"), modifiers: []), assigned: custom) == .keep)
    }
}

@Suite struct CullingFilterTests {
    let materials = [
        CatalogFixture.video(prompt: "rejected dance", minutesAgo: 5, culling: .rejected),
        CatalogFixture.video(prompt: "kept dance", minutesAgo: 6, culling: .kept),
        CatalogFixture.image(prompt: "rejected knight", minutesAgo: 7, culling: .rejected),
        CatalogFixture.image(prompt: "knight", minutesAgo: 8),
    ]
    var rows: [LibraryMediaItem] { CatalogFixture.rows(materials) }
    var index: LibraryCatalogIndex { LibraryCatalogIndex(materials) }

    private func shown(_ filter: LibraryFilter, kind: LibraryKind) -> [UUID] {
        filter.apply(filter.culled(rows, index: index), kind: kind).map(\.id)
    }

    @Test func rejectedResultsStayOutOfEveryTab() {
        let filter = LibraryFilter()
        #expect(shown(filter, kind: .all) == [materials[1].id, materials[3].id])
        #expect(shown(filter, kind: .video) == [materials[1].id])
        #expect(shown(filter, kind: .image) == [materials[3].id])
        #expect(filter.counts(filter.culled(rows, index: index)) == LibraryKindCounts(videos: 1, images: 1))
    }

    @Test func searchNeverBringsThemBack() {
        let filter = LibraryFilter(query: "rejected")
        #expect(shown(filter, kind: .all).isEmpty)
        #expect(shown(filter, kind: .video).isEmpty)
        #expect(shown(filter, kind: .image).isEmpty)
    }

    @Test func showRejectedBringsThemBackWithTheOtherFilters() {
        let filter = LibraryFilter(query: "rejected", showsRejected: true)
        #expect(shown(filter, kind: .all) == [materials[0].id, materials[2].id])
        #expect(shown(filter, kind: .image) == [materials[2].id])
        #expect(filter.counts(filter.culled(rows, index: index)) == LibraryKindCounts(videos: 1, images: 1))
        #expect(!LibraryFilter(showsRejected: true).isActive)
        #expect(!LibraryFilter(showsRejected: true).cleared.showsRejected)
    }
}

@Suite struct VariantGroupTests {
    @Test func videoVariantsFoldIntoOneCardInsteadOfABatch() {
        let group = UUID()
        let batch = UUID()
        let materials = [
            CatalogFixture.video(group: group, batch: batch, minutesAgo: 1),
            CatalogFixture.video(group: group, batch: batch, minutesAgo: 2),
            CatalogFixture.video(group: group, batch: batch, minutesAgo: 3),
            CatalogFixture.video(minutesAgo: 4),
        ]
        let rows = CatalogFixture.rows(materials)
        let groups = LibraryVariantGroups(rows, index: LibraryCatalogIndex(materials))
        #expect(groups.members[group] == materials.prefix(3).map(\.id))
        #expect(groups.faces[group] == materials[0].id)
        #expect(groups.collapse(rows, expanded: []).map(\.id) == [materials[0].id, materials[3].id])
        #expect(groups.collapsedCount(of: materials[0].id, expanded: []) == 3)
        #expect(groups.collapsedCount(of: materials[3].id, expanded: []) == nil)
        #expect(groups.collapse(rows, expanded: [group]).count == 4)
        #expect(groups.collapsedCount(of: materials[0].id, expanded: [group]) == nil)

        let videos = rows.compactMap { row -> LibraryItemModel? in
            if case .video(let item) = row { item } else { nil }
        }
        let entries = LibraryEntry.group(videos, variants: groups.groupedIDs)
        #expect(entries.count == 4)
        #expect(LibraryEntry.group(videos).count == 2)
    }

    @Test func imageCountVariantsShowTheirPrimary() {
        let group = UUID()
        let materials = [
            CatalogFixture.image(group: group, minutesAgo: 1),
            CatalogFixture.image(group: group, minutesAgo: 2, isPrimary: true),
            CatalogFixture.image(group: group, minutesAgo: 3),
        ]
        let rows = CatalogFixture.rows(materials)
        let groups = LibraryVariantGroups(rows, index: LibraryCatalogIndex(materials))
        #expect(groups.faces[group] == materials[1].id)
        #expect(groups.collapse(rows, expanded: []).map(\.id) == [materials[1].id])
        #expect(groups.collapsedCount(of: materials[1].id, expanded: []) == 3)
    }

    @Test func mixedGridGroupsOnlyWhatIsShown() {
        let images = UUID()
        let videos = UUID()
        let materials = [
            CatalogFixture.image(group: images, minutesAgo: 1),
            CatalogFixture.video(group: videos, minutesAgo: 2),
            CatalogFixture.image(group: images, minutesAgo: 3, culling: .rejected, isPrimary: true),
            CatalogFixture.video(group: videos, minutesAgo: 4),
            CatalogFixture.image(group: images, minutesAgo: 5),
            CatalogFixture.image(minutesAgo: 6),
        ]
        let index = LibraryCatalogIndex(materials)
        let filter = LibraryFilter()
        let shown = filter.apply(filter.culled(CatalogFixture.rows(materials), index: index), kind: .all)
        let groups = LibraryVariantGroups(shown, index: index)
        // The rejected primary is hidden, so the first variant shown stands in for it.
        #expect(groups.members[images] == [materials[0].id, materials[4].id])
        #expect(groups.faces[images] == materials[0].id)
        #expect(groups.members[videos] == [materials[1].id, materials[3].id])
        #expect(
            groups.collapse(shown, expanded: []).map(\.id) == [materials[0].id, materials[1].id, materials[5].id])

        // A search that leaves one variant shows it as a card of its own.
        let one = LibraryVariantGroups(Array(shown.prefix(1)), index: index)
        #expect(one.members.isEmpty)
        #expect(one.group(of: materials[0].id) == nil)
    }

    @Test func collapsingKeepsTheSelection() {
        let group = UUID()
        let materials = [
            CatalogFixture.image(group: group, minutesAgo: 1), CatalogFixture.image(group: group, minutesAgo: 2),
        ]
        let rows = CatalogFixture.rows(materials)
        let groups = LibraryVariantGroups(rows, index: LibraryCatalogIndex(materials))
        let selected = Set(materials.map(\.id))
        let collapsed = groups.collapse(rows, expanded: []).map(\.id)
        #expect(CullingTargets.resolve(visible: collapsed, selected: selected, current: nil) == [materials[0].id])
        let expanded = groups.collapse(rows, expanded: [group]).map(\.id)
        #expect(CullingTargets.resolve(visible: expanded, selected: selected, current: nil) == materials.map(\.id))
    }
}

@Suite struct CullingScopeTests {
    let ids = (0..<5).map { _ in UUID() }

    @Test func theScopeIsTheVisibleSelectionInGridOrder() {
        let hidden = UUID()
        let selected: Set<UUID> = [ids[3], ids[1], hidden]
        #expect(CullingTargets.resolve(visible: ids, selected: selected, current: ids[0]) == [ids[1], ids[3]])
        #expect(CullingTargets.title(count: 2) == "2 selected")
    }

    @Test func withoutASelectionTheCurrentCardIsTheScope() {
        #expect(CullingTargets.resolve(visible: ids, selected: [], current: ids[2]) == [ids[2]])
        #expect(CullingTargets.resolve(visible: ids, selected: [UUID()], current: ids[2]) == [ids[2]])
        #expect(CullingTargets.resolve(visible: ids, selected: [], current: UUID()).isEmpty)
        #expect(CullingTargets.resolve(visible: ids, selected: [], current: nil).isEmpty)
    }

    @Test func arrowsMoveThroughTheGrid() {
        #expect(LibraryCursor.moved(nil, .right, in: ids, columns: 2) == ids[0])
        #expect(LibraryCursor.moved(ids[0], .right, in: ids, columns: 2) == ids[1])
        #expect(LibraryCursor.moved(ids[0], .left, in: ids, columns: 2) == ids[0])
        #expect(LibraryCursor.moved(ids[1], .down, in: ids, columns: 2) == ids[3])
        #expect(LibraryCursor.moved(ids[3], .down, in: ids, columns: 2) == ids[4])
        #expect(LibraryCursor.moved(ids[3], .up, in: ids, columns: 2) == ids[1])
        #expect(LibraryCursor.columns(width: 1000, minimum: 230, spacing: 18) == 4)
        #expect(LibraryCursor.columns(width: 100, minimum: 230, spacing: 18) == 1)
    }

    @Test func cullingAdvancesSoASeriesNeedsOnlyKeys() {
        #expect(LibraryCursor.advanced(after: ids[1], in: ids, leaves: true) == ids[2])
        #expect(LibraryCursor.advanced(after: ids[4], in: ids, leaves: false) == ids[4])
        #expect(LibraryCursor.advanced(after: ids[4], in: ids, leaves: true) == ids[3])
    }

    @Test func fortyResultsCullWithKeysAloneAndUndoTakesBackTheLast() {
        var materials = (0..<40).map { CatalogFixture.image(minutesAgo: Double($0)) }
        var history = CullingHistory()
        let filter = LibraryFilter()
        var current: UUID?
        func visible() -> [UUID] {
            filter.apply(
                filter.culled(CatalogFixture.rows(materials), index: LibraryCatalogIndex(materials)), kind: .all
            )
            .map(\.id)
        }
        current = LibraryCursor.moved(current, .right, in: visible(), columns: 4)
        for step in 0..<40 {
            let ids = visible()
            let action: CullingAction = step.isMultiple(of: 3) ? .reject : .keep
            let targets = CullingTargets.resolve(visible: ids, selected: [], current: current)
            let writes = history.apply(action, to: targets, in: LibraryCatalogIndex(materials)) ?? [:]
            for (reference, culling) in writes {
                if let index = materials.firstIndex(where: { $0.id == reference.materialID }) {
                    materials[index].current.culling = culling
                }
            }
            current = LibraryCursor.advanced(after: targets[0], in: ids, leaves: action == .reject)
        }
        #expect(materials.allSatisfy { $0.current.culling != .unreviewed })
        #expect(visible().count == 26)
        let last = history.undo()
        #expect(last?.count == 1)
        #expect(last?.values.first == .unreviewed)
        #expect(last?.keys.first?.materialID == materials[39].id)
    }
}

@Suite struct VariantCompareTests {
    let images = (0..<3).map {
        CompareImage(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/\($0).png"), prompt: "variant \($0)")
    }

    @Test func theRightSideStepsThroughTheOthers() throws {
        var compare = try #require(VariantCompare(images))
        #expect(compare.pair == ImageComparePair(images[0], images[1]))
        compare.step(1)
        #expect(compare.pair == ImageComparePair(images[0], images[2]))
        compare.step(1)
        #expect(compare.pair == ImageComparePair(images[0], images[1]))
        compare.step(-1)
        #expect(compare.pair == ImageComparePair(images[0], images[2]))
        #expect(compare.position == "Variant 3 of 3")
        compare.swap()
        #expect(compare.pair == ImageComparePair(images[2], images[0]))
        #expect(VariantCompare(Array(images.prefix(1))) == nil)
    }
}

struct CullingToggleTests {
    @Test func theLitVerdictPressedAgainTakesItBack() {
        #expect(CullingAction.reject.toggled(against: [.rejected]) == .clear)
        #expect(CullingAction.keep.toggled(against: [.kept, .kept]) == .clear)
    }

    @Test func anotherVerdictOrAMixedSelectionIsSet() {
        #expect(CullingAction.reject.toggled(against: [.kept]) == .reject)
        #expect(CullingAction.reject.toggled(against: [.rejected, .unreviewed]) == .reject)
        #expect(CullingAction.keep.toggled(against: []) == .keep)
        #expect(CullingAction.clear.toggled(against: [.unreviewed]) == .clear)
    }
}
