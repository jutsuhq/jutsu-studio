import JutsuCore
import Presentation
import SwiftUI

/// What subtitles are made for: an exact version of a library video, its file, and the file's bookmark.
struct SubtitleTarget: Identifiable {
    let id = UUID()
    let source: MaterialReference
    let file: URL
    let bookmark: Data?
    /// The item's title, under the sheet's.
    let title: String
}

/// The language subtitles are heard in, and that it is free. Before the first run in a language whose model isn't on
/// this Mac it asks to let macOS download it, and nothing downloads until then. Starting adds the run to
/// `SubtitleRuns`, which runs one at a time; the item's card shows how far it is.
struct SubtitlesSheet: View {
    let target: SubtitleTarget

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var language = ""
    @State private var agreesToDownload = false

    private var runs: SubtitleRuns { environment.subtitles }

    /// By name in the app's language.
    private var languages: [(String, String)] {
        runs.languages.map { ($0, SubtitleText.languageName($0)) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private var needsConsent: Bool { !language.isEmpty && runs.needsConsent(language) }

    private var canStart: Bool {
        !language.isEmpty && runs.model(for: language) != nil && runs.run(for: target.source.materialID) == nil
            && (!needsConsent || agreesToDownload)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SubtitleText.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(target.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            options
            if needsConsent { consent }
            notes
            actions
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .task {
            await runs.loadAvailability()
            if language.isEmpty { language = runs.preferredLanguage ?? "" }
        }
        // The person agrees per language: macOS downloads a model per locale.
        .onChange(of: language) { agreesToDownload = false }
    }

    @ViewBuilder private var options: some View {
        SectionLabel(title: "Language")
        if runs.availability == nil {
            ProgressView().controlSize(.small)
        } else {
            Picker("Language", selection: $language) {
                ForEach(languages, id: \.0) { identifier, name in Text(name).tag(identifier) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(SubtitleText.modelNotice)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(SubtitleText.modelConsent, isOn: $agreesToDownload)
                .toggleStyle(.checkbox)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(OnDeviceText.price)
            Text(SubtitleText.soundNote)
            Text(SubtitleText.versionNote)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            Spacer(minLength: Theme.Spacing.small)
            Button("Cancel") { dismiss() }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button {
                start()
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Label("Make Subtitles", systemImage: "captions.bubble")
                    PriceTag(text: String(localized: "Free"))
                }
            }
            .buttonStyle(.primaryAction)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
    }

    private func start() {
        if needsConsent { runs.agreeToModel(for: language) }
        runs.start(
            SubtitleRuns.Request(
                source: target.source, file: target.file, bookmark: target.bookmark, language: language))
        dismiss()
    }
}

/// "Subtitles…" in a video's menus, or Cancel while its subtitles are being made.
struct SubtitlesMenuButton: View {
    let item: LibraryItemModel

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let run = environment.subtitles.run(for: item.id) {
            Button("Cancel Subtitles", systemImage: "xmark.circle") { environment.subtitles.cancel(run.id) }
        } else if item.outputFile != nil, !item.needsImport {
            Button("Subtitles…", systemImage: "captions.bubble") {
                Task { await environment.openSubtitles(for: item) }
            }
            .help("Make subtitles from the speech in this video, free on this Mac")
        }
    }
}

/// A result page's subtitles: the run making them, with Cancel, or what the current version has, and Subtitles….
struct SubtitlesSection: View {
    let item: LibraryItemModel
    /// The current version's, `nil` when it has none.
    let subtitles: Subtitles?
    /// Opens the editor beside the player.
    let edit: (Subtitles) -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let run = environment.subtitles.run(for: item.id) {
                HStack(spacing: Theme.Spacing.small) {
                    if let fraction = run.state.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(SubtitleText.progress(of: run))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Button("Cancel") { environment.subtitles.cancel(run.id) }
                        .buttonStyle(.link)
                }
            } else if item.outputFile != nil, !item.needsImport {
                if let subtitles {
                    Text(SubtitleText.summary(of: subtitles))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Button {
                        edit(subtitles)
                    } label: {
                        Label("Edit Subtitles", systemImage: "captions.bubble.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryAction)
                }
                Button {
                    Task { await environment.openSubtitles(for: item) }
                } label: {
                    Label(
                        subtitles == nil
                            ? String(localized: "Subtitles…") : String(localized: "Make Subtitles Again…"),
                        systemImage: "captions.bubble"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryAction)
            }
        }
    }
}
