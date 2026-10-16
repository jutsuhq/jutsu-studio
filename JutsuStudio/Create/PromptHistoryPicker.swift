import Persistence
import Presentation
import SwiftData
import SwiftUI

/// The clock button next to the prompt: opens the history of submitted prompts; picking one replaces the Create
/// draft's prompt, with Undo when that loses an edited one.
struct PromptHistoryButton: View {
    @Environment(NavigationModel.self) private var navigation
    @AppStorage(AppSettings.promptHistoryClearedAtKey) private var clearedAt = 0.0
    @State private var isOpen = false

    var body: some View {
        Button("Prompt History", systemImage: "clock.arrow.circlepath") { isOpen = true }
            .buttonStyle(.iconAction)
            .hoverHint("Reuse an earlier prompt")
            .popover(isPresented: $isOpen, arrowEdge: .trailing) {
                PromptHistoryPicker(clearedAt: AppSettings.promptHistoryClearedAt(clearedAt)) { text in
                    navigation.replaceDraft { $0.prompt = text }
                    isOpen = false
                }
            }
    }
}

/// The cross next to a prompt's title: `clear` empties the prompt.
struct PromptClearButton: View {
    let clear: () -> Void

    var body: some View {
        Button("Clear Prompt", systemImage: "xmark", action: clear)
            .buttonStyle(.iconAction)
            .hoverHint("Clear the prompt")
    }
}

private struct PromptHistoryPicker: View {
    let clearedAt: Date?
    let onPick: (String) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Query private var jobs: [JobRecord]
    @Query(StarredPromptRecord.newestFirst) private var starred: [StarredPromptRecord]
    @State private var query = ""
    @State private var errorText: String?

    init(clearedAt: Date?, onPick: @escaping (String) -> Void) {
        self.clearedAt = clearedAt
        self.onPick = onPick
        _jobs = Query(JobRecord.withPrompts(after: clearedAt))
    }

    private var items: [PromptHistoryItem] {
        let uses = jobs.map { PromptUse(text: $0.prompt, date: $0.createdAt) }
        let stars = starred.map { PromptUse(text: $0.text, date: $0.starredAt) }
        return PromptHistory.search(
            PromptHistory.items(uses: uses, starred: stars, clearedAt: clearedAt), query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SearchField(text: $query, prompt: String(localized: "Search prompts"))
            let items = items
            if items.isEmpty {
                Text(query.isEmpty ? "Prompts of jobs you submit appear here." : "No prompt matches.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.xSmall) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 380, height: 360)
        .background(Theme.background)
    }

    private func row(_ item: PromptHistoryItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Button {
                onPick(item.text)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let lastUsed = item.lastUsed {
                        Text(lastUsed.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(Theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .hoverHint("Use this prompt")
            Button(
                item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.fill" : "star"
            ) {
                setStarred(!item.isStarred, item.text)
            }
            .buttonStyle(.iconAction)
            .foregroundStyle(item.isStarred ? Theme.accent : Theme.muted)
            .hoverHint(item.isStarred ? "Unstar" : "Star to keep it on top")
        }
        .padding(Theme.Spacing.small)
        .well()
    }

    private func setStarred(_ isStarred: Bool, _ text: String) {
        do {
            try environment.setStarred(isStarred, prompt: text)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
