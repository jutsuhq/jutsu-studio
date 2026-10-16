import AppKit
import JutsuCore
import MediaKit
import Persistence
import Presentation
import QuickLook
import SwiftData
import SwiftUI
import os

/// Finished results, newest first, with search and filters; a result opens on its own page, a batch of results
/// as a comparison grid. Videos and images share one grid under the All/Videos/Images tabs; the origin switch
/// picks this Mac or the Higgsfield account, whose images join the grid once its history loads. That history's
/// results are downloaded only when opened or exported.
struct LibraryView: View {
    @Query(sort: \MaterialRecord.createdAt, order: .reverse)
    var records: [MaterialRecord]

    @Environment(AppEnvironment.self) var environment
    @StoredShortcut(.refreshHistory) var refreshShortcut
    @StoredShortcut(.keep) var keepShortcut
    @StoredShortcut(.reject) var rejectShortcut
    @StoredShortcut(.clearCulling) var clearCullingShortcut
    @Environment(ConnectionStore.self) var connection
    @Environment(NavigationModel.self) var navigation
    @Environment(\.modelContext) var modelContext
    @State var origin = LibraryOrigin.local
    @State var kind = LibraryKind.all
    @State var filter = LibraryFilter()
    @State var selection: UUID?
    /// The batch whose comparison grid is open; a result opened from it goes back to it.
    @State var batchSelection: UUID?
    @State var quickLookURL: URL?
    @State var exportMessage: UserMessage?
    /// Two results on the compare page, over the grid or a result's page.
    @State var comparing: ComparePair?
    /// Picking results to compare in the grid; `nil` while cards open their page.
    @State var picker: ComparePicker?
    /// Results picked for bulk actions with ⌘-click, ⇧-click or ⌘A.
    @State var selected = LibrarySelection()
    /// Results waiting for the delete confirmation.
    @State var pendingDelete: [LibraryItemModel]?
    /// The batch whose starred drafts' finals are being set up.
    @State var finalsBatch: LibraryBatch?
    /// Images picked with a click or ⌘-click; picking one clears the results' selection, and the other way round.
    @State var imageSelected: Set<UUID> = []
    /// Images waiting for the Trash and removal confirmations.
    @State var pendingImageTrash: Set<UUID>?
    @State var pendingImageRemoval: Set<UUID>?
    /// Picking images to compare in the grid.
    @State var imagePicker: ComparePicker?
    /// Two images on the compare page, over the grid.
    @State var comparingImages: ImageComparePair?
    /// Account images being downloaded, by generation ID.
    @State var downloadingImages: Set<UUID> = []
    /// Account images already downloaded for viewing or comparing, by generation ID.
    @State var downloadedImages: [UUID: URL] = [:]
    /// The card the arrow keys moved to; the culling keys act on it while nothing is selected.
    @State var cursor: UUID?
    /// How many cards a row of the grid holds, for ↑ and ↓.
    @State var gridColumns = 1
    /// Variant groups shown as every variant instead of one card.
    @State var expandedGroups: Set<UUID> = []
    /// This session's keep, reject and clear, for ⌘Z.
    @State var cullingHistory = CullingHistory()
    /// An image variant group stepped through in Compare.
    @State var comparingVariants: VariantCompare?
    /// The image version whose details sheet is open: its prompt, what it was made from and the videos made from it.
    @State var imageDetails: MaterialReference?
    /// The delivery sets sheet, open on one set.
    @State var deliverySets: DeliverySetsRoute?
    /// The grid or the large viewer has the keyboard, so single-key culling never fires while typing.
    @FocusState var hasKeyboard: Bool

    var body: some View {
        withLibrarySync(withLibraryDialogs(main()))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle("Library")
    }

    func gridData() throws -> LibraryGridData {
        let materials = try records.map { try $0.material() }
        let index = LibraryCatalogIndex(materials)
        let local = materials.filter { $0.current.fileURL != nil }.compactMap(MaterialLibrary.row)
        let all = local.compactMap { row -> LibraryItemModel? in
            if case .video(let item) = row { return item }
            return nil
        }
        let origin =
            origin == .local
            ? local
            : materials.filter {
                $0.remote?.provider == .account && $0.remote?.owner == environment.provider?.owner
            }.compactMap(MaterialLibrary.row)
        // Rejected results leave before the search, the filters and the counts see them.
        let rows = filter.culled(origin, index: index)
        return LibraryGridData(
            all: all, videoRows: rows.filter(\.isVideo), rows: rows, counts: filter.counts(rows),
            index: index, materials: materials, isEmpty: origin.isEmpty)
    }

    private func main() -> some View {
        let snapshot = Result { try gridData() }
        return Group {
            switch snapshot {
            case .failure(let error):
                EmptyState(
                    systemImage: "exclamationmark.triangle", title: "Can't open the material catalog",
                    detail: error.localizedDescription)
            case .success(let data):
                if let comparingVariants {
                    ImageCompareView(variants: comparingVariants) { self.comparingVariants = nil }
                } else if let comparingImages {
                    ImageCompareView(pair: comparingImages) { self.comparingImages = nil }
                        .id(comparingImages)
                } else if let comparing {
                    LibraryCompare(pair: comparing) { self.comparing = nil }
                        .id(comparing)
                } else if let item = data.all.first(where: { $0.id == selection }) {
                    detail(
                        item, among: videoItems(in: data.videoRows), all: data.all, index: data.index,
                        materials: data.materials)
                } else if let batchID = batchSelection,
                    let batch = LibraryBatch(
                        id: batchID, in: data.all.filter { filter.showsRejected || !data.index.isRejected($0.id) })
                {
                    BatchComparison(
                        batch: batch, open: { selection = $0 }, deleteUnstarred: { pendingDelete = $0 },
                        renderFinals: { finalsBatch = batch }, close: { batchSelection = nil })
                } else {
                    content(data)
                }
            }
        }
        .background { cullingUndoShortcut }
    }

    private func withLibraryDialogs<V: View>(_ view: V) -> some View {
        view
            .alert(
                exportMessage?.title ?? "", isPresented: Binding(isPresenting: $exportMessage),
                presenting: exportMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message.message)
            }
            .confirmationDialog(
                LibraryDeleteConfirmation.title(count: pendingDelete?.count ?? 1),
                isPresented: Binding(isPresenting: $pendingDelete), titleVisibility: .visible,
                presenting: pendingDelete
            ) { items in
                Button(LibraryDeleteConfirmation.confirmTitle, role: .destructive) { delete(items) }
            } message: { items in
                Text(LibraryDeleteConfirmation.message(count: items.count))
            }
            .confirmationDialog(
                String(localized: "Move \(pendingImageTrash?.count ?? 0) images to the Trash?"),
                isPresented: Binding(isPresenting: $pendingImageTrash), presenting: pendingImageTrash
            ) { ids in
                Button("Move to Trash", role: .destructive) { trashImages(ids) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("You can put them back from the Trash in Finder.")
            }
            .confirmationDialog(
                String(localized: "Remove \(pendingImageRemoval?.count ?? 0) images from the library?"),
                isPresented: Binding(isPresenting: $pendingImageRemoval), presenting: pendingImageRemoval
            ) { ids in
                Button("Remove from Library", role: .destructive) { removeImages(ids) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $finalsBatch) { RenderFinalsSheet(batch: $0) }
            .sheet(item: $deliverySets) { DeliverySetsSheet(route: $0) }
            .sheet(isPresented: Binding(isPresenting: $imageDetails)) {
                if let imageDetails { imageDetailsSheet(imageDetails) }
            }
    }

    private func withLibrarySync<V: View>(_ view: V) -> some View {
        view
            .onChange(of: navigation.libraryFocus, initial: true) { _, focus in
                guard let focus else { return }
                filter = filter.cleared
                selected.clear()
                imageSelected = []
                batchSelection = nil
                comparing = nil
                comparingImages = nil
                picker = nil
                imagePicker = nil
                selection = focus
                navigation.libraryFocus = nil
            }
            .onChange(of: origin) {
                filter = LibraryFilter(query: filter.query, showsRejected: filter.showsRejected, sort: filter.sort)
                cursor = nil
                selected.clear()
                imageSelected = []
                picker = nil
                imagePicker = nil
            }
            .onChange(of: kind) {
                selected.clear()
                imageSelected = []
                picker = nil
                imagePicker = nil
            }
            // Looks again for the image files each time the local origin opens: a drive connected since shows its
            // images again. Refreshed whenever the Higgsfield origin opens and when the account changes.
            .task(id: HistoryKey(origin: origin, owner: environment.history.owner)) {
                if origin == .local {
                    await environment.imageLibrary.load()
                } else {
                    await environment.loadHistory(refresh: true)
                }
            }
            .onChange(of: environment.imageLibrary.failure) { _, failure in
                if let failure { exportMessage = failure }
            }
    }
}

/// The origin's rows, with the query and filters' counts: one struct so the branches share it.
struct LibraryGridData {
    var all: [LibraryItemModel]
    var videoRows: [LibraryMediaItem]
    var rows: [LibraryMediaItem]
    var counts: LibraryKindCounts
    var index: LibraryCatalogIndex
    /// The whole catalog, decoded once for the snapshot; a result's page reads its relations from it.
    var materials: [JutsuCore.Material]
    /// The origin has nothing at all, rejected results included.
    var isEmpty: Bool
}
