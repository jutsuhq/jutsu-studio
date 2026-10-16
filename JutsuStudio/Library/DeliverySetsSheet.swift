import AppKit
import JutsuCore
import MediaKit
import Observation
import Persistence
import Presentation
import SwiftData
import SwiftUI
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Library")

/// Which set the delivery sets sheet opens on.
struct DeliverySetsRoute: Identifiable {
    let id = UUID()
    var selection: UUID?
}

/// Library › Delivery Sets: every set on the left, the chosen one on the right. A sheet over the Library rather than a
/// page of its own, since a set is made from the Library's selection and its items are the Library's versions.
struct DeliverySetsSheet: View {
    @Query(sort: \DeliverySetRecord.createdAt, order: .reverse)
    private var records: [DeliverySetRecord]
    @Query(sort: \MaterialRecord.createdAt, order: .reverse)
    private var materialRecords: [MaterialRecord]

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var exporter = DeliveryExportModel()
    @State private var message: UserMessage?
    /// The last write, so edits reach the store in the order they were made.
    @State private var lastSave: Task<Void, Never>?

    init(route: DeliverySetsRoute) {
        _selection = State(initialValue: route.selection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 940, height: 640)
        .background(Theme.background)
        .alert(
            message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
        .onAppear { selection = selection ?? records.first?.id }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(DeliveryContent.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding([.horizontal, .top], Theme.Spacing.large)
            List(selection: $selection) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text((try? record.deliverySet()).map(DeliveryContent.status) ?? "")
                            .font(.caption)
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                    .tag(record.id)
                }
            }
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(exporter.isRunning)
            }
            .padding(Theme.Spacing.large)
        }
    }

    @ViewBuilder private var detail: some View {
        if let record = records.first(where: { $0.id == selection }) {
            switch Result(catching: { try record.deliverySet() }) {
            case .success(let set):
                DeliverySetDetail(
                    set: set, materials: materials(), exporter: exporter,
                    save: save, startNextRound: startNextRound, delete: delete, report: { message = $0 }
                )
                .id(set.id)
            case .failure(let error):
                EmptyState(
                    systemImage: "exclamationmark.triangle", title: "Can't open this delivery set",
                    detail: error.localizedDescription)
            }
        } else {
            EmptyState(
                systemImage: "shippingbox", title: "No delivery set selected",
                detail: String(
                    localized:
                        "Select videos or images in the Library and choose New Delivery Set to fix their versions for a delivery."
                ))
        }
    }

    /// The catalog, decoded while the sheet is open, for the items' pictures and files.
    private func materials() -> [JutsuCore.Material] {
        materialRecords.compactMap { try? $0.material() }
    }

    private func save(_ set: DeliverySet) {
        let store = environment.store
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            do {
                try await store.saveDeliverySet(set)
            } catch {
                logger.error("Can't save a delivery set: \(String(describing: error), privacy: .private)")
                message = UserMessage(
                    title: String(localized: "Couldn't save the delivery set"),
                    message: error as? DeliverySetError == .frozen
                        ? DeliveryContent.frozenMessage : error.localizedDescription)
            }
        }
    }

    /// A new set of the same materials at their newest versions, opened at once.
    private func startNextRound(from set: DeliverySet) {
        let byID = Dictionary(materials().map { ($0.id, $0.reference) }) { first, _ in first }
        let next = set.nextRound(name: DeliveryContent.nextRoundName(after: set.name)) { byID[$0] }
        save(next)
        selection = next.id
    }

    private func delete(_ set: DeliverySet) {
        let store = environment.store
        Task {
            do {
                try await store.deleteDeliverySet(id: set.id)
                selection = records.first { $0.id != set.id }?.id
            } catch {
                message = UserMessage(
                    title: String(localized: "Couldn't delete the delivery set"), message: error.localizedDescription)
            }
        }
    }
}

/// One delivery run at a time: the files of a set written one after another off the main actor (`DeliveryRun`,
/// `DeliveryExporter`), with each file's state for the sheet.
@MainActor
@Observable
final class DeliveryExportModel {
    struct Finished {
        var results: [DeliveryResult]
        var folder: DeliverySet.Folder
        var date: Date
    }

    /// Each file's state in the current or last run, by `DeliveryTask.id`.
    private(set) var states: [String: DeliveryRun.State] = [:]
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Writes `scope`'s files of `set` into `folder`, reading each item's file from `versions`, then writes the
    /// manifest and calls `finish` with what to record on the set.
    func start(
        _ set: DeliverySet, scope: DeliveryPlan.Scope, folder: DeliverySet.Folder,
        versions: [MaterialReference: MaterialVersion], finish: @escaping (Finished) -> Void
    ) {
        guard task == nil else { return }
        isRunning = true
        states = [:]
        task = Task {
            defer {
                isRunning = false
                task = nil
            }
            let access = SecurityScopedAccess(url: folder.url, bookmark: folder.bookmark)
            let directory = access.url
            let existing = Set(
                ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
                    .map { $0.lowercased() })
            let tasks = DeliveryPlan.tasks(for: set, scope: scope) { existing.contains($0.lowercased()) }
            let results = await DeliveryRun.run(tasks) { task in
                try await Self.export(task, version: versions[task.item.reference], into: directory)
            } report: { id, state in
                self.states[id] = state
            }
            let date = Date()
            // A stale bookmark is made again with write access; the one `SecurityScopedAccess` refreshes is read-only.
            let bookmark =
                access.refreshedBookmark == nil
                ? folder.bookmark : (try? FileLayout.bookmarkData(for: directory)) ?? folder.bookmark
            let finished = Finished(
                results: results, folder: DeliverySet.Folder(url: directory, bookmark: bookmark), date: date)
            if !results.isEmpty {
                var recorded = set
                recorded.record(results, in: finished.folder, at: date)
                // Never written over a file of the same name that an earlier run to this folder didn't write.
                let ownsManifest = set.folder?.url.standardizedFileURL == directory.standardizedFileURL
                Self.writeManifest(of: recorded, at: date, into: directory, replacing: ownsManifest)
            }
            withExtendedLifetime(access) {}
            finish(finished)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private static func export(_ task: DeliveryTask, version: MaterialVersion?, into directory: URL) async throws {
        guard let version, let file = version.fileURL, version.availability == .available else {
            throw DeliverySetError.sourceUnavailable
        }
        _ = try await SecurityScopedAccess.withAccess(to: file, bookmark: version.bookmark) { url in
            try await DeliveryExporter.export(task, source: url, into: directory) { _ in }
        }
    }

    /// The set's manifest next to its files; the files are delivered either way, so a failure is only logged.
    private static func writeManifest(of set: DeliverySet, at date: Date, into directory: URL, replacing: Bool) {
        let file = directory.appending(path: ExportNaming.deliveryManifestName(set: set.name))
        do {
            let manifest = ExportSidecar.Delivery(set: set, exportedAt: date)
            try manifest.encoded().write(to: file, options: replacing ? .atomic : .withoutOverwriting)
        } catch {
            logger.error("Can't write a delivery manifest: \(String(describing: error), privacy: .private)")
        }
    }
}
