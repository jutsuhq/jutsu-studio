import Persistence
import Presentation
import SwiftData
import SwiftUI

/// Disk use of results, prepared sources, preset previews and downloaded inputs, with Clear Cache and removing old
/// drafts.
struct StorageSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(filter: #Predicate<JobRecord> { $0.isTerminal == false }) private var activeJobs: [JobRecord]
    @State private var usage: StorageUsage?
    @State private var draftDays = OldDrafts.defaultDays
    @State private var oldDrafts: [OldDraft]?
    @State private var isConfirmingClear = false
    @State private var draftConfirmation: OldDrafts.Confirmation?
    /// The drafts the open confirmation counted; exactly these move.
    @State private var confirmedDrafts: [OldDraft] = []
    @State private var errorText = ""
    @State private var isShowingError = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Disk use",
                footer: String(localized: "Results count only files of jobs in the library.")
            ) {
                SettingsRow(
                    label: "Results", value: usage?.resultsText ?? String(localized: "Measuring…"),
                    isFirst: true)
                SettingsRow(label: "Prepared sources", value: sizeText(usage?.sources))
                SettingsRow(label: "Preset previews", value: sizeText(usage?.cache))
                SettingsRow(label: "Motion Library and uploads", value: sizeText(usage?.media))
            }
            SettingsSection(
                title: "Cache",
                footer: isBusy
                    ? String(
                        localized:
                            "Available when the queue and image requests are done: they still use their prepared files."
                    )
                    : nil
            ) {
                SettingsRow(label: "Clear cache", detail: cacheDetail, isFirst: true) {
                    Button("Clear Cache") { isConfirmingClear = true }
                        .buttonStyle(.secondaryAction)
                        .disabled(cacheBytes == 0 || isBusy)
                }
            }
            SettingsSection(
                title: "Old drafts",
                footer: String(
                    localized: "Draft results go to the Trash. The library keeps their jobs, inputs and costs.")
            ) {
                SettingsRow(label: "Older than", isFirst: true) {
                    SegmentedControl(
                        selection: $draftDays,
                        options: OldDrafts.dayOptions.map { ($0, String(localized: "\($0) days")) }
                    )
                    .fixedSize()
                }
                SettingsRow(
                    label: "Remove drafts",
                    detail: oldDrafts.map(OldDrafts.summary) ?? String(localized: "Measuring…")
                ) {
                    Button("Move to Trash…") {
                        confirmedDrafts = oldDrafts ?? []
                        draftConfirmation = OldDrafts.confirmation(confirmedDrafts, days: draftDays)
                    }
                    .buttonStyle(.secondaryAction)
                    .disabled(oldDrafts?.isEmpty ?? true)
                }
            }
        }
        .task { await measure() }
        .task(id: draftDays) { await findDrafts() }
        .confirmationDialog("Clear the cache?", isPresented: $isConfirmingClear) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearCache() }
            }
        } message: {
            Text(
                """
                Prepared sources, preset previews and downloaded Motion Library clips and uploads are deleted. \
                The library, templates, the files in the Create form and your results stay.
                """)
        }
        .confirmationDialog(
            draftConfirmation?.title ?? "", isPresented: Binding(isPresenting: $draftConfirmation),
            presenting: draftConfirmation
        ) { _ in
            Button("Move to Trash", role: .destructive) {
                let drafts = confirmedDrafts
                Task { await trash(drafts) }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("Can't free the space", isPresented: $isShowingError) {
            Button("OK") {}
        } message: {
            Text(errorText)
        }
    }

    private var cacheBytes: Int64? {
        usage?.cacheBytes
    }

    private var cacheDetail: String {
        cacheBytes.map { AppSettings.cacheSizeText(bytes: $0) } ?? String(localized: "Measuring…")
    }

    private func sizeText(_ bytes: Int64?) -> String {
        bytes.map { $0 > 0 ? AppSettings.formatBytes($0) : String(localized: "Empty") }
            ?? String(localized: "Measuring…")
    }

    private func measure() async {
        do {
            usage = try await environment.storageUsage()
        } catch {
            show(error)
        }
    }

    private func findDrafts() async {
        do {
            oldDrafts = try await environment.oldDrafts(olderThan: draftDays)
        } catch {
            show(error)
        }
    }

    /// Jobs or image requests that still read the cache: their uploads and downloads are staged there.
    private var isBusy: Bool { !activeJobs.isEmpty || environment.imageWork.running > 0 }

    private func clearCache() async {
        do {
            try await environment.clearCache()
        } catch {
            show(error)
        }
        await measure()
    }

    private func trash(_ drafts: [OldDraft]) async {
        do {
            try await environment.trash(drafts)
        } catch {
            show(error)
        }
        for draft in drafts { ThumbnailCache.shared.forget(draft.file) }
        await findDrafts()
        await measure()
    }

    private func show(_ error: any Error) {
        errorText = error.localizedDescription
        isShowingError = true
    }
}
