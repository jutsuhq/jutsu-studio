import AppKit
import JutsuCore
import Persistence
import Presentation
import SwiftUI

/// One delivery set: its exact versions, outputs, status, note and review link, and the export actions. Every edit is
/// saved as it is made; once exported, the items stay as they are and only frames, outputs and text change.
struct DeliverySetDetail: View {
    let materials: [JutsuCore.Material]
    let exporter: DeliveryExportModel
    let save: (DeliverySet) -> Void
    let startNextRound: (DeliverySet) -> Void
    let delete: (DeliverySet) -> Void
    let report: (UserMessage?) -> Void

    @State private var draft: DeliverySet
    @State private var framing: FramingTarget?
    @State private var confirmsDelete = false
    @FocusState private var focus: Field?

    private enum Field { case name, note, link }

    /// The item whose crop for one aspect is being moved.
    struct FramingTarget: Identifiable {
        var item: DeliverySet.Item
        var aspect: CropAspect
        var id: String { "\(item.reference.versionID)/\(aspect.key)" }
    }

    init(
        set: DeliverySet, materials: [JutsuCore.Material], exporter: DeliveryExportModel,
        save: @escaping (DeliverySet) -> Void, startNextRound: @escaping (DeliverySet) -> Void,
        delete: @escaping (DeliverySet) -> Void, report: @escaping (UserMessage?) -> Void
    ) {
        _draft = State(initialValue: set)
        self.materials = materials
        self.exporter = exporter
        self.save = save
        self.startNextRound = startNextRound
        self.delete = delete
        self.report = report
    }

    var body: some View {
        let relations = MaterialRelations(materials)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    header
                    items(relations)
                    outputs
                    notes
                }
                .padding(Theme.Spacing.large)
            }
            Divider()
            footer(relations)
                .padding(Theme.Spacing.large)
        }
        .onChange(of: draft) { _, changed in save(changed) }
        .sheet(item: $framing) { target in
            DeliveryFrameSheet(
                item: target.item, aspect: target.aspect,
                link: relations.link(to: target.item.reference, kind: target.item.kind)
            ) { frame in
                draft.setFrame(frame, for: target.item.reference, aspect: target.aspect)
            }
        }
        .confirmationDialog(
            String(localized: "Delete “\(draft.name)”?"), isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button("Delete Set", role: .destructive) { delete(draft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Exported files and the library's versions stay where they are.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            TextField("Set name", text: $draft.name)
                .themedField(isFocused: focus == .name)
                .focused($focus, equals: .name)
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: draft.isFrozen ? "lock.fill" : "lock.open")
                    .foregroundStyle(draft.isFrozen ? Theme.accent : Theme.faint)
                Text(DeliveryContent.status(of: draft))
                    .foregroundStyle(Theme.muted)
                if let summary = DeliveryContent.summary(DeliveryCounts(draft)) {
                    Text(verbatim: "·").foregroundStyle(Theme.faint)
                    Text(summary).foregroundStyle(Theme.muted)
                }
            }
            .font(.caption)
            .hoverHint(
                draft.isFrozen
                    ? DeliveryContent.frozenMessage
                    : String(localized: "The set's versions are fixed when it is first exported."))
        }
    }

    private func items(_ relations: MaterialRelations) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Items", detail: "\(draft.items.count)")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 128), spacing: Theme.Spacing.medium)],
                alignment: .leading, spacing: Theme.Spacing.medium
            ) {
                ForEach(draft.items) { item in itemTile(item, relations: relations) }
            }
        }
    }

    private func itemTile(_ item: DeliverySet.Item, relations: MaterialRelations) -> some View {
        let aspects = Self.aspects(of: draft.outputs, for: item.kind)
        return VStack(alignment: .leading, spacing: 4) {
            MaterialPreview(link: relations.link(to: item.reference, kind: item.kind))
                .frame(width: 128, height: 96)
                .overlay(alignment: .topTrailing) { DeliveryItemBadge(state: state(of: item)).padding(6) }
            Text(item.name.isEmpty ? String(localized: "Untitled") : item.name)
                .font(.caption)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 4) {
                if aspects.count == 1, let aspect = aspects.first {
                    Button("Frame \(aspect.title)…") { framing = FramingTarget(item: item, aspect: aspect) }
                } else if !aspects.isEmpty {
                    Menu("Frame…") {
                        ForEach(aspects, id: \.self) { aspect in
                            Button(aspect.title) { framing = FramingTarget(item: item, aspect: aspect) }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
                if !draft.isFrozen {
                    Button("Remove", systemImage: "minus.circle") {
                        try? draft.setItems(draft.items.filter { $0.reference != item.reference })
                    }
                    .labelStyle(.iconOnly)
                    .hoverHint("Take this item out of the set")
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .disabled(exporter.isRunning)
        }
        .frame(width: 128, alignment: .leading)
    }

    private var outputs: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Outputs", detail: "\(draft.outputs.count)")
            ForEach($draft.outputs) { $output in
                DeliveryOutputRow(output: $output) {
                    draft.outputs.removeAll { $0.id == output.id }
                }
            }
            HStack(spacing: Theme.Spacing.small) {
                Button("Add Image Output", systemImage: "photo") {
                    draft.outputs.append(DeliveryOutput(preset: .image(ImageExportPreset(format: .jpeg))))
                }
                Button("Add Video Output", systemImage: "film") {
                    draft.outputs.append(DeliveryOutput(preset: .video(.editingH264)))
                }
            }
            .buttonStyle(.secondaryAction)
        }
        .disabled(exporter.isRunning)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Note")
            TextField("What this round is for, what changed", text: $draft.note, axis: .vertical)
                .lineLimit(1...4)
                .themedField(isFocused: focus == .note)
                .focused($focus, equals: .note)
            SectionLabel(title: "Review link")
            TextField("Where the client reviews it (text only)", text: $draft.reviewLink)
                .themedField(isFocused: focus == .link)
                .focused($focus, equals: .link)
        }
    }

    // MARK: Actions

    private func footer(_ relations: MaterialRelations) -> some View {
        let failed = DeliveryPlan.tasks(for: draft, scope: .failed) { _ in false }.count
        let pending = DeliveryPlan.tasks(for: draft, scope: .pending) { _ in false }.count
        return HStack(spacing: Theme.Spacing.small) {
            Button("New Set from This One", systemImage: "arrow.triangle.branch") { startNextRound(draft) }
                .hoverHint("Start the next round with the items' newest versions")
            if let folder = draft.folder {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            Spacer(minLength: Theme.Spacing.small)
            if exporter.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel Export") { exporter.cancel() }
            } else if draft.isFrozen {
                if failed > 0 {
                    Button("Retry \(failed) Failed") { export(.failed, relations: relations, to: draft.folder) }
                }
                Button {
                    export(.pending, relations: relations, to: draft.folder)
                } label: {
                    if pending > 0 { Text("Export \(pending) Pending") } else { Text("Exported") }
                }
                .buttonStyle(.primaryAction)
                .disabled(pending == 0)
                .hoverHint(
                    "Write only what isn't exported as the set is now: new outputs, a fixed crop, failed or skipped files"
                )
            } else {
                Button("Export…") { export(.all, relations: relations, to: nil) }
                    .buttonStyle(.primaryAction)
                    .disabled(draft.items.isEmpty || draft.outputs.isEmpty)
            }
        }
        .buttonStyle(.secondaryAction)
    }

    /// Runs the export into `folder`, asking for one when there is none yet.
    private func export(_ scope: DeliveryPlan.Scope, relations: MaterialRelations, to folder: DeliverySet.Folder?) {
        guard let folder = folder ?? Self.chooseFolder() else { return }
        let versions = Dictionary(
            draft.items.compactMap { item in relations.version(item.reference).map { (item.reference, $0) } }
        ) { first, _ in first }
        exporter.start(draft, scope: scope, folder: folder, versions: versions) { finished in
            draft.record(finished.results, in: finished.folder, at: finished.date)
            let counts = DeliveryCounts(draft)
            if counts.failed > 0 || counts.skipped > 0 {
                report(
                    UserMessage(
                        title: String(localized: "Some files weren't exported"),
                        message: DeliveryContent.summary(counts) ?? ""))
            }
        }
    }
}

extension DeliverySetDetail {
    private static func chooseFolder() -> DeliverySet.Folder? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = EditingExportContent.folderPrompt
        panel.message = String(
            localized: "Choose a folder for the delivery. Files made by others are never replaced.")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return DeliverySet.Folder(url: url, bookmark: try? FileLayout.bookmarkData(for: url))
    }

    // MARK: State

    /// The aspects an item is cropped to: those of the outputs of its kind, once each.
    private static func aspects(of outputs: [DeliveryOutput], for kind: JutsuCore.Material.Kind) -> [CropAspect] {
        var seen: Set<CropAspect> = []
        return outputs.filter { $0.kind == kind }.compactMap(\.aspect).filter { seen.insert($0).inserted }
    }

    /// The item's files taken together: the run's states while it runs, else the recorded results.
    private func state(of item: DeliverySet.Item) -> DeliveryRun.State? {
        let outputs = draft.outputs.filter { $0.kind == item.kind }
        if exporter.isRunning {
            let states = outputs.compactMap { exporter.states["\(item.reference.versionID)/\($0.id)"] }
            return DeliveryItemBadge.combined(states)
        }
        let states: [DeliveryRun.State] = outputs.compactMap { output in
            switch draft.result(for: item, output: output)?.status {
            case .done?: .done
            case .failed?: .failed(draft.result(for: item, output: output)?.message ?? "")
            case .skipped?: .skipped(draft.result(for: item, output: output)?.message ?? "")
            case nil: nil
            }
        }
        return DeliveryItemBadge.combined(states)
    }
}

/// Done, failed, skipped or running, over an item's picture.
struct DeliveryItemBadge: View {
    let state: DeliveryRun.State?

    /// The state that matters most: running, then failed, skipped, waiting and done.
    static func combined(_ states: [DeliveryRun.State]) -> DeliveryRun.State? {
        if states.contains(.running) { return .running }
        if let failed = states.first(where: { if case .failed = $0 { true } else { false } }) { return failed }
        if let skipped = states.first(where: { if case .skipped = $0 { true } else { false } }) { return skipped }
        if states.contains(.waiting) { return .waiting }
        return states.isEmpty ? nil : .done
    }

    var body: some View {
        switch state {
        case .running?:
            ProgressView().controlSize(.mini)
        case .waiting?:
            symbol("clock", Theme.faint, hint: String(localized: "Waiting"))
        case .done?:
            symbol("checkmark.circle.fill", Theme.accent, hint: String(localized: "Exported"))
        case .failed(let message)?:
            symbol("exclamationmark.circle.fill", Theme.danger, hint: message)
        case .skipped(let message)?:
            symbol("minus.circle.fill", Theme.warning, hint: message)
        case nil:
            EmptyView()
        }
    }

    private func symbol(_ name: String, _ color: Color, hint: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(color)
            .background(Circle().fill(Theme.background).padding(1))
            .hoverHint(hint)
    }
}
