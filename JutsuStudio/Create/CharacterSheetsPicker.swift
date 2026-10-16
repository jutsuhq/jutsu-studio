import JutsuCore
import Presentation
import SwiftUI

/// References › From Higgsfield › Characters: the account's character sheets as a grid, with Create Character… on
/// top. Picking a sheet adds it as one reference image: a video job of the same account names it by its job ID, which
/// Genjutsu's `generate_video` takes as an image reference. Sheets still being made show as placeholders and appear
/// here when they finish.
struct CharacterSheetsPicker: View {
    /// How many more references the form takes.
    let limit: Int
    let onAdd: ([LocalImage]) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var adding: String?
    @State private var failure: String?
    /// The download `add` started: closing the sheet cancels it, so a Cancel adds nothing.
    @State private var downloading: Task<Void, Never>?
    @State private var accountFeed: PagedFeed<CharacterSheet>?

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: Theme.Spacing.small)]

    private var owner: String? { environment.characterMaker?.owner }

    /// The sheets made here, then the account's others when its list is read.
    private var sheets: [CharacterSheet] {
        let made = environment.madeCharacterSheets
        let others = (accountFeed?.items ?? []).filter { sheet in !made.contains { $0.id == sheet.id } }
        return made + others
    }

    private var pendingCount: Int { environment.characterBuilder.pendingCount(of: owner) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
                .onDisappear { downloading?.cancel() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
                        ForEach(0..<pendingCount, id: \.self) { _ in PendingTile() }
                        ForEach(sheets) { tile($0) }
                    }
                    footer
                }
            }
            .frame(maxHeight: .infinity)
            actions
        }
        .task(id: environment.providerGeneration) {
            accountFeed = environment.accountCharacterSheetsFeed()
            await accountFeed?.loadIfNeeded()
        }
        .sheet(isPresented: $isCreating) {
            CreateCharacterSheet()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Characters")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Character sheets of your account. Pick one to use it as a reference image.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.Spacing.small)
            Button {
                isCreating = true
            } label: {
                Label("Create Character…", systemImage: "person.crop.square.badge.plus")
            }
            .buttonStyle(.primaryAction)
        }
    }

    private func tile(_ sheet: CharacterSheet) -> some View {
        Button {
            add(sheet)
        } label: {
            Theme.well
                .aspectRatio(1, contentMode: .fit)
                .overlay { SheetThumbnail(sheet: sheet) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                }
                .overlay {
                    if adding == sheet.id { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(adding != nil || limit <= 0)
        .help(limit <= 0 ? String(localized: "References are full.") : "")
        .accessibilityLabel(String(localized: "Character sheet"))
    }

    /// Why only the sheets made here are listed; the account's next page; or an empty list's hint.
    @ViewBuilder private var footer: some View {
        if let feed = accountFeed {
            PagedFeedFooter(feed)
        } else {
            Label(
                "Only the characters made in Jutsu Studio are listed. Sheets made on higgsfield.ai aren't shown yet.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(Theme.faint)
        }
        if sheets.isEmpty && pendingCount == 0 && accountFeed?.hasMore != true {
            EmptyState(
                systemImage: "person.crop.square", title: "No characters yet",
                detail: String(localized: "Create a character: a sheet of one person or animal from every side.")
            )
            .padding(.top, 40)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let failure {
                Text(failure)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.small)
            if adding != nil { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func add(_ sheet: CharacterSheet) {
        adding = sheet.id
        failure = nil
        downloading = Task {
            defer { adding = nil }
            do {
                let reference = try await environment.characterReference(sheet)
                guard !Task.isCancelled else { return }
                onAdd([reference])
                dismiss()
            } catch {
                failure = (UserMessage(error, kind: .account)?.title) ?? String(localized: "Can't download the sheet")
            }
        }
    }
}

/// A sheet's saved copy when there is one, else its link. The copy is in Library › Images, in an output folder whose
/// access stays open for the whole launch, so the thumbnail needs no bookmark.
private struct SheetThumbnail: View {
    let sheet: CharacterSheet

    var body: some View {
        if let file = sheet.fileURL {
            ReferenceThumb(reference: LocalImage(fileURL: file, bookmark: nil))
        } else {
            RemoteThumbnail(url: sheet.thumbnailURL ?? sheet.imageURL, maxPixelSize: 320)
        }
    }
}
