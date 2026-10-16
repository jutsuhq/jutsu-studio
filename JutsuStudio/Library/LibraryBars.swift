import AppKit
import JutsuCore
import Presentation
import SwiftUI

/// What the Higgsfield source shows instead of the grid.
struct HistoryPlaceholderView: View {
    let placeholder: HistoryPlaceholder

    var body: some View {
        switch placeholder {
        case .unavailable(let title, let detail):
            EmptyState(systemImage: "person.crop.circle.badge.questionmark", title: title, detail: detail)
        case .failed(let message):
            EmptyState(systemImage: "exclamationmark.triangle", title: message.title, detail: message.message) {
                HistoryRetryButton()
            }
        case .loading:
            ProgressView("Loading your Higgsfield history…").controlSize(.small)
        case .empty:
            EmptyState(
                systemImage: "film", title: HistoryAvailability.emptyTitle, detail: HistoryAvailability.emptyDetail)
        }
    }
}

/// Under the Higgsfield grid: loads the next page when it scrolls into view; a failed page offers a retry instead.
/// After the last page, says that Styles made elsewhere aren't listed.
struct HistoryFooter: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let history = environment.history
        if case .failed(let message) = history.phase {
            HStack(spacing: Theme.Spacing.small) {
                Text(message.title).foregroundStyle(Theme.muted)
                HistoryRetryButton()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.large)
        } else if history.isWaitingToLoadMore {
            Button("Load More") {
                Task { await environment.loadHistory(refresh: false) }
            }
            .buttonStyle(.secondaryAction)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.large)
        } else if history.hasMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.large)
                .task(id: history.pagingProgress) { await environment.loadHistory(refresh: false) }
        } else if !history.items.isEmpty {
            Text(HistoryAvailability.stylesNote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.large)
        }
    }
}

private struct HistoryRetryButton: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button("Try Again") {
            Task { await environment.loadHistory(refresh: !environment.history.hasLoaded) }
        }
        .buttonStyle(.secondaryAction)
    }
}

/// "Pick one more · Compare · Cancel" while results are being picked; Escape cancels.
struct ComparePickBar: View {
    let prompt: String
    /// `nil` until two results are picked.
    let pair: ComparePair?
    let onCancel: () -> Void
    let onCompare: (ComparePair) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(prompt)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: Theme.Spacing.small)
            Button("Cancel", action: onCancel)
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button("Compare", systemImage: "rectangle.split.2x1") {
                if let pair { onCompare(pair) }
            }
            .buttonStyle(.primaryAction)
            .keyboardShortcut(.defaultAction)
            .disabled(pair == nil)
        }
    }
}

/// The Library's kind tabs with their counts, between the origin switch and the filter bar: stronger than the
/// filters, weaker than the origin, and never on either's row.
struct LibraryKindTabs: View {
    @Binding var kind: LibraryKind
    let counts: LibraryKindCounts

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ForEach(LibraryKind.allCases) { option in
                Button {
                    kind = option
                } label: {
                    HStack(spacing: 4) {
                        Text(option.title)
                        Text(counts.count(for: option), format: .number)
                            .foregroundStyle(Theme.faint)
                    }
                    .font(.system(size: 13, weight: kind == option ? .bold : .semibold))
                    .foregroundStyle(kind == option ? Theme.accent : Theme.muted)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityAddTraits(kind == option ? .isSelected : [])
            }
        }
    }
}

/// The Library's filters: only the ones that can change the current kind's grid and have a choice to make
/// (`LibraryFilterOptions`). A menu lists only the values the origin has; an on-or-off filter is a toggle.
struct LibraryFilterBar: View {
    @Binding var filter: LibraryFilter
    let kind: LibraryKind
    let options: LibraryFilterOptions

    var body: some View {
        let fields = LibraryFilter.Field.visible(for: kind).filter { options.shows($0, in: filter) }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) { menus(fields) }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) { menus(fields) }
            }
        }
    }

    @ViewBuilder private func menus(_ fields: [LibraryFilter.Field]) -> some View {
        ForEach(fields, id: \.self) { field in menu(field) }
    }

    @ViewBuilder private func menu(_ field: LibraryFilter.Field) -> some View {
        switch field {
        case .mode:
            FilterMenu(
                title: String(localized: "Mode"), selection: $filter.mode,
                options: [(nil, String(localized: "Any mode"))] + options.modes.map { ($0, $0.title) })
        case .model:
            FilterMenu(
                title: String(localized: "Video model"), selection: $filter.model,
                options: [(nil, String(localized: "Any video model"))] + options.models.map { ($0, $0.title) })
        case .resolution:
            FilterMenu(
                title: String(localized: "Resolution"), selection: $filter.resolution,
                options: [(nil, String(localized: "Any resolution"))] + options.resolutions.map { ($0, $0.rawValue) })
        case .finish:
            FilterMenu(
                title: String(localized: "Finish"), selection: $filter.finish,
                options: [
                    (.all, String(localized: "Drafts and finals")), (.drafts, String(localized: "Drafts only")),
                    (.finals, String(localized: "Finals only")),
                ])
        case .imageModel:
            FilterMenu(
                title: String(localized: "Image model"), selection: $filter.imageModel,
                options: [(nil, String(localized: "Any image model"))] + options.imageModels.map { ($0, $0) })
        case .imageAspectRatio:
            FilterMenu(
                title: String(localized: "Aspect"), selection: $filter.imageAspectRatio,
                options: [(nil, String(localized: "Any aspect"))] + options.imageAspects.map { ($0, $0) })
        case .starred:
            FilterToggle(
                title: String(localized: "Starred"), systemImage: filter.isStarredOnly ? "star.fill" : "star",
                isOn: $filter.isStarredOnly)
        case .rejected:
            FilterToggle(
                title: String(localized: "Show rejected"), systemImage: filter.showsRejected ? "eye" : "eye.slash",
                isOn: $filter.showsRejected)
        case .sort:
            FilterMenu(
                title: String(localized: "Sort"), selection: $filter.sort,
                options: LibraryFilter.Sort.allCases.map { ($0, $0.title) })
        }
    }
}

/// "3 selected" with the bulk actions over the grid while results are selected; Escape clears the selection.
struct LibrarySelectionBar<Actions: View>: View {
    let title: String
    let onDone: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.small)
            HStack(spacing: Theme.Spacing.small) { actions }
                .buttonStyle(.secondaryAction)
            Button("Done", action: onDone)
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
                .hoverHint("Clear the selection (Esc)")
        }
    }
}

/// What the Library shows instead of the grid: no results saved yet, or none that match the filters.
struct LibraryEmptyState: View {
    var hasNoResults: Bool

    var body: some View {
        if hasNoResults {
            EmptyState(
                systemImage: "film", title: "No results yet",
                detail: String(localized: "Finished videos are saved to your output folder and appear here.")
            )
        } else {
            EmptyState(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "Nothing matches these filters"
            )
        }
    }
}

/// What the Library reloads the Higgsfield history on: the origin shown and whose account it is.
struct HistoryKey: Hashable {
    let origin: LibraryOrigin
    let owner: String?
}
