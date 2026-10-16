import AppKit
import JutsuCore
import Persistence
import Presentation
import SwiftData
import SwiftUI
import os

extension LibraryView {
    /// The origin's videos in grid order, filtered but before the kind tab picks.
    func videoItems(in videoRows: [LibraryMediaItem]) -> [LibraryItemModel] {
        filter.apply(videoRows, kind: .video).compactMap {
            guard case .video(let item) = $0 else { return nil }
            return item
        }
    }

    /// Steps through `items`, the grid's results; a focused job the filters hide still opens, alone.
    func detail(
        _ item: LibraryItemModel, among items: [LibraryItemModel], all: [LibraryItemModel],
        index catalog: LibraryCatalogIndex, materials: [JutsuCore.Material]
    ) -> some View {
        let index = items.firstIndex { $0.id == item.id }
        // One scan of the catalog for the open result only, never per card.
        let madeFrom = catalog.entries[item.id].map { MaterialRelations(materials).madeFrom($0.reference) } ?? []
        let cull = { (action: CullingAction) in cullShown(action, item, among: items, index: catalog) }
        return LibraryDetail(
            item: item, record: records.first { $0.id == item.id },
            position: index.map { $0 + 1 } ?? 1, count: index == nil ? 1 : items.count,
            chain: LibraryChain(for: item.id, in: all),
            parent: item.job.parentID.flatMap { parentID in all.first { $0.id == parentID } },
            madeFrom: madeFrom,
            showImage: { imageDetails = $0 },
            step: { offset in
                guard let index, items.indices.contains(index + offset) else { return }
                selection = items[index + offset].id
            },
            open: { selection = $0 },
            compareCandidates: ComparePair.candidates(for: item, in: all),
            compare: { other in comparing = ComparePair(item, other) },
            close: { selection = nil },
            culling: catalog.culling(of: item.id), cull: cull
        )
        .id(item.id)
        .focusable()
        .focused($hasKeyboard)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let shortcut = Shortcut(press), let action = CullingAction.pressed(shortcut, assigned: cullingKeys)
            else { return .ignored }
            cull(action)
            return .handled
        }
        .onAppear { hasKeyboard = true }
    }

    /// Culls the result the large viewer shows, then steps to the next one, so a series is culled from here too.
    /// Taking a verdict back (Clear, or the lit Keep or Reject again) stays on it.
    func cullShown(
        _ action: CullingAction, _ item: LibraryItemModel, among items: [LibraryItemModel],
        index: LibraryCatalogIndex
    ) {
        let applied = cull(action, [item.id], index: index)
        guard applied != .clear else { return }
        let leaves = applied == .reject && !filter.showsRejected
        if let next = LibraryCursor.advanced(after: item.id, in: items.map(\.id), leaves: leaves) {
            selection = next
            cursor = next
        }
    }

    static let subtitle = String(localized: "Every finished video and image, also saved to your output folder.")

    var availability: HistoryAvailability { HistoryAvailability(connection.state) }

    /// The grid's cards once filtered and folded: a collapsed variant group shows only its face, and its videos
    /// never fold into a batch card as well. One pass over the rows each.
    func layout(_ rows: [LibraryMediaItem], index: LibraryCatalogIndex) -> LibraryGridLayout {
        let videos = kind == .image ? [] : videoItems(in: rows.filter(\.isVideo))
        let images = kind == .video ? [] : filter.apply(rows.filter { !$0.isVideo }, kind: .image)
        let groups = LibraryVariantGroups(ids: videos.map(\.id) + images.map(\.id), index: index)
        let shownVideos = groups.collapse(videos, expanded: expandedGroups)
        let shownImages = groups.collapse(images, expanded: expandedGroups)
        let entries = LibraryEntry.group(shownVideos, variants: groups.groupedIDs)
        return LibraryGridLayout(
            rows: LibraryMediaGrid.arrange(entries: entries, images: shownImages, sort: filter.sort),
            entries: entries, videos: shownVideos, images: shownImages, groups: groups, index: index)
    }

    func content(_ data: LibraryGridData) -> some View {
        let rows = data.rows
        let layout = layout(rows, index: data.index)
        let videos = layout.videos
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Library", subtitle: Self.subtitle) {
                headerControls(isEmpty: data.isEmpty)
            }
            LibraryKindTabs(kind: $kind, counts: data.counts)
                .padding(.bottom, Theme.Spacing.small)
            if !data.isEmpty {
                LibraryFilterBar(filter: $filter, kind: kind, options: LibraryFilterOptions(rows))
                    .padding(.bottom, Theme.Spacing.large)
            }
            pickBars(videos: videos, rows: rows)
            selectionBars(layout)
            // A spinner or an empty state takes the rest of the page, centered in it, like the grid does.
            mainSection(layout, rows: rows, isEmpty: data.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pinned to the top: a short section (the account's history loading) would otherwise center the page and
        // move the header down when the origin switches.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.pageTop)
        .libraryCommands(gridCommands(picker == nil ? selected.items(in: videos) : []))
        // The keys reach here only when no text field has them, so single-key culling never fires while typing.
        .focusable()
        .focused($hasKeyboard)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { gridKey($0, layout: layout) }
        .onAppear { hasKeyboard = true }
    }

    /// "Pick one more" while results or images are picked to compare.
    @ViewBuilder
    func pickBars(videos: [LibraryItemModel], rows: [LibraryMediaItem]) -> some View {
        if let picker {
            ComparePickBar(
                prompt: picker.prompt, pair: picker.pair(in: videos), onCancel: { self.picker = nil },
                onCompare: { pair in
                    comparing = pair
                    self.picker = nil
                }
            )
            .padding(.bottom, Theme.Spacing.large)
        }
        if let picker = imagePicker {
            ImageComparePickBar(
                prompt: picker.prompt, ready: imagePair(from: picker, in: rows) != nil,
                onCancel: { imagePicker = nil },
                onCompare: {
                    if let pair = imagePair(from: picker, in: rows) {
                        comparingImages = pair
                        imagePicker = nil
                    }
                }
            )
            .padding(.bottom, Theme.Spacing.large)
        }
    }

    /// The bulk-action bars over the grid while results or images are selected.
    /// Only what is on screen counts: a collapsed group's other variants stay selected but aren't acted on.
    @ViewBuilder
    func selectionBars(_ layout: LibraryGridLayout) -> some View {
        let chosen = selected.items(in: layout.videos)
        if picker == nil, !chosen.isEmpty, kind != .image {
            LibrarySelectionBar(title: LibraryBulkActions(chosen).title, onDone: { selected.clear() }) {
                CullingButtons(count: chosen.count) { cull($0, chosen.map(\.id), index: layout.index) }
                Button(DeliveryContent.newSetTitle, systemImage: "shippingbox") { newDeliverySet(chosen.map(\.id)) }
                LibraryBulkButtons(items: chosen, actions: cardActions)
            }
            .padding(.bottom, Theme.Spacing.large)
        }
        let chosenImages = layout.images.filter { imageSelected.contains($0.id) }
        if imagePicker == nil, !chosenImages.isEmpty, kind != .video {
            LibraryImageSelectionBar(
                chosen: chosenImages, unavailable: environment.imageLibrary.unavailable,
                onDone: { imageSelected = [] }, actions: imageActions,
                cull: { cull($0, chosenImages.map(\.id), index: layout.index) }
            )
            .padding(.bottom, Theme.Spacing.large)
        }
    }

    /// The grid, or what shows instead of it: the history's placeholder, an empty state, or the images' own.
    @ViewBuilder
    func mainSection(_ layout: LibraryGridLayout, rows: [LibraryMediaItem], isEmpty: Bool) -> some View {
        let gridRows = layout.rows
        if origin == .higgsfield,
            let placeholder = HistoryPlaceholder(
                availability: availability, history: environment.history, isEmpty: isEmpty)
        {
            HistoryPlaceholderView(placeholder: placeholder)
                .frame(maxHeight: .infinity)
        } else if isEmpty {
            LibraryEmptyState(hasNoResults: true)
                .frame(maxHeight: .infinity)
        } else if gridRows.isEmpty {
            if kind == .image, imagesTotal(in: rows) == 0 {
                ImageEmptyState(origin: origin)
                    .frame(maxHeight: .infinity)
            } else {
                LibraryEmptyState(hasNoResults: false)
                    .frame(maxHeight: .infinity)
            }
        } else {
            grid(layout)
        }
    }

    func headerControls(isEmpty: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            SegmentedControl(selection: $origin) { $0.title }
                .fixedSize()
            if !isEmpty {
                SearchField(text: $filter.query, prompt: String(localized: "Search prompts and names"))
                    .frame(width: 260)
                if picker == nil, imagePicker == nil {
                    Button("Compare", systemImage: "rectangle.split.2x1") {
                        if kind == .image {
                            imagePicker = ComparePicker()
                        } else {
                            startComparing()
                        }
                    }
                    .buttonStyle(.iconAction)
                    .hoverHint(kind == .image ? "Compare two images" : "Compare two results")
                }
            }
            Button(DeliveryContent.title, systemImage: "shippingbox") { deliverySets = DeliverySetsRoute() }
                .buttonStyle(.iconAction)
                .hoverHint("Open delivery sets")
            if origin == .higgsfield, availability == .available {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await environment.loadHistory(refresh: true) }
                }
                .buttonStyle(.iconAction)
                .keyboardShortcut(refreshShortcut)
                .disabled(environment.history.isLoading)
                .hoverHint(
                    $refreshShortcut.map { String(localized: "Refresh (\($0.displayText))") }
                        ?? String(localized: "Refresh"))
            } else {
                // Keeps the row as wide on both origins, so the header never moves under the title on one of them.
                Color.clear.frame(width: 34, height: 34)
            }
        }
    }

    func grid(_ layout: LibraryGridLayout) -> some View {
        let gridRows = layout.rows
        // One clock for every card's "36 min ago".
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, so the history footer only loads the next page once it scrolls into view.
                    LazyVStack(spacing: 0) {
                        cards(layout, now: context.date)
                        if origin == .higgsfield { HistoryFooter() }
                    }
                    .padding(.bottom, Theme.Spacing.page)
                }
                .refreshable {
                    if origin == .higgsfield { await environment.loadHistory(refresh: true) }
                }
                // The arrow keys keep the current card in view.
                .onChange(of: cursor) { _, cursor in
                    if let cursor { proxy.scrollTo(cursor) }
                }
            }
        }
        .quickLookPreview($quickLookURL, in: quickLookFiles(gridRows))
        .background {
            if picker == nil {
                // ⌘A over the grid selects every visible card of the current kind; while a text field is edited
                // it selects the text.
                TextAwareShortcut("Select All", key: "a", textAction: #selector(NSText.selectAll(_:))) {
                    selected.selectAll(LibraryKindSelection.entries(for: kind, in: gridRows))
                    imageSelected = LibraryKindSelection.imageIDs(for: kind, in: gridRows)
                }
            }
        }
    }

    /// The files Quick Look steps through: every local result and image, and the file being previewed itself.
    func quickLookFiles(_ gridRows: [LibraryGridRow]) -> [URL] {
        var files: [URL] = []
        for row in gridRows {
            switch row {
            case .entry(let entry): files += entry.items.compactMap(\.outputFile)
            case .image(.localImage(let image)): files.append(image.fileURL)
            case .image(.video), .image(.remoteImage): break
            }
        }
        files += downloadedImages.values.filter { !files.contains($0) }
        if let quickLookURL, !files.contains(quickLookURL) { files.append(quickLookURL) }
        return files
    }

    func cards(_ layout: LibraryGridLayout, now: Date) -> some View {
        let entries = layout.entries
        let videos = layout.videos
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.cardWidth), spacing: Self.cardSpacing)],
            spacing: Self.cardSpacing
        ) {
            ForEach(layout.rows) { row in
                Group {
                    switch row {
                    case .entry(.item(let item)):
                        card(item, in: layout, now: now)
                    case .entry(.batch(let batch)):
                        batchCard(batch, in: entries, now: now)
                    case .image(let image):
                        imageCard(image, in: layout)
                    }
                }
                .modifier(marks(for: row.id, in: layout))
                // An edited file dropped on a card comes back as its new version.
                .dropDestination(for: URL.self) { urls, _ in dropEditedVersion(urls, on: row.id) }
            }
        }
        .onGeometryChange(for: Double.self) {
            $0.size.width
        } action: { width in
            gridColumns = LibraryCursor.columns(width: width, minimum: Self.cardWidth, spacing: Self.cardSpacing)
        }
        .resultFileDragContainer { [selected] cardID in
            entries.first { $0.id == cardID }.map { selected.dragged($0, in: videos) } ?? []
        }
    }

    static let cardWidth = 230.0
    static let cardSpacing = 18.0
}
