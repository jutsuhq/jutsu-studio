import JutsuCore
import Presentation
import SwiftUI

/// Create's Generate…: makes reference images with the connection's image models. The form is on the left and the
/// results on the right (`GenerateSheetLayout`, shared with Create Character). A click picks a result, a double click
/// opens it large, and Add puts the picked ones into References in the order they were picked, then closes. While a
/// request runs, the form and the cross wait for it; Cancel on the request stops it. Every image is saved to
/// Library › Images as it arrives (`ImageLibrary`). The form, runs and results are Generate…'s own, shared with the
/// Image side of Create, so they outlive the sheet; closing only drops the picks.
struct GenerateReferenceSheet: View {
    /// The source clip's size, for the default frame; `nil` without a source.
    let source: PixelSize?
    let mode: Mode
    /// How many more references Create takes.
    let room: Int
    /// The image IDs being downloaded to become references.
    let adding: Set<UUID>
    /// Downloads `image` and adds it to the references; the message says why it wasn't added.
    let onAdd: (GeneratedImage) async -> UserMessage?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Generate as on the Image side of Create, for this source and mode.
    @State private var controller: ImageGenerateController
    @State private var isAddingPicks = false
    @State private var isConfirmingClose = false
    /// The result open large.
    @State private var previewed: UUID?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Theme.Spacing.small)]

    init(
        source: PixelSize?, mode: Mode, room: Int, adding: Set<UUID>,
        onAdd: @escaping (GeneratedImage) async -> UserMessage?
    ) {
        self.source = source
        self.mode = mode
        self.room = room
        self.adding = adding
        self.onAdd = onAdd
        _controller = State(initialValue: ImageGenerateController(source: source, mode: mode))
    }

    private var generator: ReferenceGenerator { environment.referenceGenerator }

    /// A request is being started or runs.
    private var isGenerating: Bool { controller.isGenerating(generator) }
    private var isBusy: Bool { isGenerating || isAddingPicks }
    private var canPick: Bool { generator.selection.count < room }

    var body: some View {
        GenerateSheetLayout(
            title: String(localized: "Generate reference images"),
            subtitle: String(
                localized: "Every image is saved to Library › Images. Pick the ones to add to the references."),
            isBusy: isBusy,
            closeHint: isGenerating
                ? String(localized: "Wait for the images") : String(localized: "Close"),
            closesOnEscape: previewed == nil,
            onClose: close
        ) {
            formColumn
        } results: {
            resultsPane
        } actions: {
            actions
        }
        .overlay {
            if previewed != nil {
                GeneratedImagePreview(
                    images: generator.images, current: $previewed, pickNumber: pickNumber, canPick: canPick,
                    onToggle: { generator.toggleSelection($0, room: room) })
            }
        }
        .interactiveDismissDisabled(isBusy)
        .onDisappear { generator.clearSelection() }
        .task(id: generator.priceKey(source: source, mode: mode)) {
            await controller.refreshPrice(environment: environment)
        }
        .imageGenerateDialogs(controller, environment: environment)
        .confirmationDialog("Close without adding the picked images?", isPresented: $isConfirmingClose) {
            Button("Close", role: .destructive) { dismiss() }
            Button("Keep Picking", role: .cancel) {}
        } message: {
            Text("They stay in Library › Images, where you can add them later.")
        }
    }

    @ViewBuilder private var formColumn: some View {
        if let reason = generator.unavailableReason, generator.models.isEmpty {
            Label(reason, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(Theme.muted)
        } else {
            GenerateReferenceForm(source: source, mode: mode)
        }
    }

    // MARK: Results

    /// The images the running requests will make, shown as placeholders until they arrive.
    private var pendingCount: Int {
        generator.runs.filter { $0.state == .running }.map(\.count).reduce(0, +)
    }

    private func pickNumber(_ id: UUID) -> Int? {
        generator.selection.firstIndex(of: id).map { $0 + 1 }
    }

    /// "Pick up to 3", "2 of 3 picked".
    private var pickText: String {
        let picked = generator.selection.count
        return picked == 0
            ? String(localized: "Pick up to \(room)") : String(localized: "\(picked) of \(room) picked")
    }

    private var resultsPane: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(
                title: "Results", detail: generator.images.isEmpty ? nil : pickText)
            UnsavedRecordsWarning()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    // A finished request shows as its images; a running, failed or canceled one keeps its row.
                    ForEach(generator.runs.filter { $0.state != .finished }) { run in
                        ImageRunRow(run: run) { generator.cancel(run.id) }
                    }
                    if pendingCount == 0 && generator.images.isEmpty {
                        Text("The images you generate show here. Click one to pick it, double-click to open it large.")
                            .font(.callout)
                            .foregroundStyle(Theme.faint)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
                        ForEach(0..<pendingCount, id: \.self) { _ in PendingTile() }
                        ForEach(generator.images) { image in
                            GeneratedResultTile(
                                image: image, pickNumber: pickNumber(image.id), canPick: canPick,
                                isAdding: adding.contains(image.id),
                                onToggle: { generator.toggleSelection(image.id, room: room) },
                                onPreview: { previewed = image.id },
                                onDelete: { delete(image.id) })
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// Return adds the picks when there are some, else generates; both keys go to the large view while it's open.
    @ViewBuilder private var actions: some View {
        ImageGenerateNotice()
        Spacer(minLength: Theme.Spacing.small)
        if generator.selection.isEmpty {
            generateButton(isPrimary: true)
                .buttonStyle(.primaryAction)
                .keyboardShortcut(previewed == nil ? .defaultAction : nil)
        } else {
            generateButton(isPrimary: false)
                .buttonStyle(.secondaryAction)
            addButton
        }
    }

    /// The price rides on the button, as on Create's Generate; its help says whether Higgsfield quoted it.
    private func generateButton(isPrimary: Bool) -> some View {
        Button {
            generate()
        } label: {
            GenerateButtonLabel(
                isGenerating: isGenerating, price: controller.buttonPrice(generator), isPrimary: isPrimary)
        }
        .disabled(generator.blocker != nil || isBusy)
        .hoverHint(generator.price.map(ReferenceGenerator.priceText) ?? "")
    }

    private var addButton: some View {
        Button(action: addPicks) {
            if isAddingPicks {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Adding…")
                }
            } else {
                Label("Add \(generator.selection.count) to References", systemImage: "plus")
            }
        }
        .buttonStyle(.primaryAction)
        .keyboardShortcut(previewed == nil ? .defaultAction : nil)
        .disabled(isBusy)
        .hoverHint(isGenerating ? String(localized: "Wait for the images") : "")
    }
}

extension GenerateReferenceSheet {
    private func generate() {
        guard !isAddingPicks else { return }
        controller.generate(environment: environment)
    }

    /// Takes a result off the list and moves its saved copy to the Trash, also out of Library › Images.
    private func delete(_ id: UUID) {
        if previewed == id { previewed = nil }
        controller.delete(id, environment: environment)
    }

    /// Adds the picks in the order they were picked, then closes; a failure stops there and keeps the rest picked.
    private func addPicks() {
        guard !isBusy else { return }
        isAddingPicks = true
        Task {
            defer { isAddingPicks = false }
            for image in generator.selectedImages {
                if let message = await onAdd(image) {
                    controller.failure = message
                    return
                }
            }
            dismiss()
        }
    }

    /// Picked images not added yet are confirmed first; everything else just closes.
    private func close() {
        if generator.selection.isEmpty {
            dismiss()
        } else {
            isConfirmingClose = true
        }
    }
}
