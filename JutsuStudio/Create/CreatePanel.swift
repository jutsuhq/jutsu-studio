import JutsuCore
import Presentation
import SwiftUI
import UniformTypeIdentifiers

/// The left column of Create (`.panel`): mode, inputs, prompt, resolution, then the cost line and the buttons.
struct CreatePanel: View {
    @Binding var form: CreateForm
    let context: CreateContext
    let catalog: PresetCatalog?
    let isSubmitting: Bool
    let onImportSource: (URL) -> Void
    /// Opens the screen's one file picker; see `FilePickTarget`.
    let onPick: (FilePickTarget) -> Void
    /// Images dropped as one new batch character.
    let onAddCharacter: ([URL]) -> Void
    let onRefreshPresets: () -> Void
    /// `true` for the draft.
    let onSubmit: (Bool) -> Void
    /// Opens the account's uploaded images; `nil` without an account connection.
    var onBrowseUploads: (() -> Void)?
    /// The link being downloaded; shown in the section it goes to.
    var linkDownload: LinkDownload?
    /// Asks for a link to a video (Source) or an image (References).
    let onPasteLink: (MediaLink.Kind) -> Void
    let onCancelLink: () -> Void
    /// Generate… in References; `nil` while disconnected.
    var generation: ReferenceGeneration?
    /// Save to Higgsfield… on batch characters; `nil` without an account connection.
    var characterSaving: CharacterSaving?

    @Environment(NavigationModel.self) private var navigation
    /// What the last change of model, tab or task did to the images' roles (`CreateForm.recheckingRoles`).
    @State private var roleChange: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modePicker
                    if let roleChange {
                        RoleChangeNote(text: roleChange) { self.roleChange = nil }
                    }
                    let modelMenu = form.modelMenu(in: context)
                    if modelMenu.count > 1 {
                        modelSection(modelMenu)
                    }
                    if form.offersBatch {
                        batchToggle
                    }
                    SourceSection(
                        form: $form, onImport: onImportSource, onPick: { onPick(.source) },
                        linkDownload: linkDownload.flatMap { $0.shows(in: .video) ? $0 : nil },
                        onPasteLink: { onPasteLink(.video) }, onCancelLink: onCancelLink)
                    if form.isWithoutSource {
                        clipSection
                    }
                    if form.showsAddedLength {
                        addedLengthSection
                    }
                    if form.mode == .restyle {
                        presetSection
                    }
                    if form.isBatch && form.mode != .restyle {
                        CharacterSetsSection(
                            form: $form, onPick: { onPick(.characterSet) }, onDrop: onAddCharacter,
                            saving: characterSaving)
                    } else {
                        if form.showsFrames {
                            FramesSection(
                                form: $form, unavailableReason: context.unavailableHint(for: .seedanceFrames),
                                onPick: { onPick(.frame($0)) })
                        }
                        referencesSection
                    }
                    promptSection
                    resolutionSection
                    audioSection
                    if form.showsDraftLength {
                        draftLengthSection
                    }
                }
                .padding(Theme.Spacing.large)
            }
            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
            // Next to the buttons rather than in the scrolled form: it multiplies what they cost.
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if form.showsVariants(in: context) {
                    variantsSection
                }
                SubmitBar(form: form, context: context, isSubmitting: isSubmitting, onSubmit: onSubmit)
            }
            .padding(Theme.Spacing.large)
        }
        .card()
    }

    /// Off while Seedance starts from frames, with the reason under it.
    private var referencesSection: some View {
        let reason = form.referencesDisabledReason
        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ReferencesSection(
                form: $form, onPick: { onPick(.references) }, onBrowseUploads: onBrowseUploads,
                linkDownload: linkDownload.flatMap { $0.shows(in: .image) ? $0 : nil },
                onPasteLink: { onPasteLink(.image) }, onCancelLink: onCancelLink, generation: generation
            )
            .disabled(reason != nil)
            .opacity(reason == nil ? 1 : 0.5)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private var batchToggle: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Batch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(form.batchHint)
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
            Toggle("Batch", isOn: $form.isBatch)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
        }
        .padding(Theme.Spacing.medium)
        .well()
    }

    /// One style, or several for a batch.
    private var presetSection: some View {
        PresetSection(
            selection: form.isBatch ? form.batchPresetIDs : (form.presetID.map { [$0] } ?? []),
            detail: form.isBatch ? form.batchCountText : nil, notice: form.batchCapNotice, catalog: catalog,
            onRefresh: onRefreshPresets,
            onPick: { id in
                if form.isBatch {
                    _ = form.toggleBatchPreset(id)
                } else {
                    form.presetID = id
                }
            })
    }

    /// Only for Motion: the other models take the same video and images.
    private func modelSection(_ rows: [ModelMenuRow]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Model", detail: form.selectedModel.detail)
            ModelPicker(
                selection: Binding(get: { form.selectedModel }, set: { model in recheckRoles { $0.model = model } }),
                rows: rows)
            taskPicker
            if form.showsVideoBackground || form.showsCharacterOrientation {
                KlingOptions(form: $form, context: context)
            }
            if form.showsCinemaControls {
                CinemaOptions(form: $form, context: context)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(title: form.promptTitle, detail: form.promptCounterText)
                if !form.prompt.isEmpty {
                    // Through `replaceDraft`, so the toast offers the prompt back with Undo.
                    PromptClearButton { navigation.replaceDraft { $0.prompt = "" } }
                }
                PromptHistoryButton()
            }
            TextEditor(text: $form.prompt)
                .font(.body)
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.small)
                .frame(minHeight: 72, maxHeight: 140)
                .overlay(alignment: .topLeading) {
                    if form.prompt.isEmpty {
                        // Lined up with the editor's first line.
                        Text(form.promptHint)
                            .font(.body)
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, Theme.Spacing.small + 5)
                            .padding(.vertical, Theme.Spacing.small)
                            .allowsHitTesting(false)
                    }
                }
                .well()
        }
    }

    /// Kling's quality takes the place of the resolutions.
    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if form.showsKlingQuality {
                SectionLabel(title: "Quality", detail: form.rateText(in: context))
                SegmentedControl(selection: $form.klingQuality) { $0.title }
            } else {
                SectionLabel(title: "Resolution", detail: form.rateText(in: context))
                SegmentedControl(
                    selection: $form.pickedResolution, options: form.resolutionOptions.map { ($0, $0.rawValue) })
            }
            if form.showsBitrate {
                BitratePicker(form: $form, context: context)
                    .padding(.top, Theme.Spacing.small)
            }
        }
    }

    /// The length and frame of a clip made without a source; with one, the trim and the video set them.
    private var clipSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Length", detail: CostText.limit(form.clipLength))
            Slider(
                value: Binding(get: { form.clipLength }, set: { form.length = $0.rounded() }),
                in: form.limits.duration, step: 1
            )
            .controlSize(.small)
            .tint(Theme.accent)
            .accessibilityValue(CostText.limit(form.clipLength))
            // Seven frames don't fit a segmented row in the panel. From a start frame, the clip takes its frame.
            if !form.usesFrames {
                HStack(spacing: Theme.Spacing.small) {
                    SectionLabel(title: "Frame")
                    FilterMenu(
                        title: String(localized: "Frame"), selection: $form.aspectRatio,
                        options: AspectRatio.allCases.map { ($0, $0.title) })
                }
                .padding(.top, Theme.Spacing.small)
            }
        }
    }

    /// Extend: how much it adds after the end of the selection.
    private var addedLengthSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: form.addedLengthTitle, detail: CostText.limit(form.clipLength))
            Slider(
                value: Binding(get: { form.clipLength }, set: { form.length = $0.rounded() }),
                in: form.limits.duration, step: 1
            )
            .controlSize(.small)
            .tint(Theme.accent)
            .accessibilityLabel(form.addedLengthTitle)
            .accessibilityValue(CostText.limit(form.clipLength))
        }
    }

    /// From the source; without one, or for what Extend adds, the model makes the sound unless it is turned off.
    private var audioSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if form.generatesAudio {
                SectionLabel(
                    title: "Audio", detail: String(localized: "Made by \(form.selectedModel.title)"))
                SegmentedControl(
                    selection: Binding(get: { form.audio != .mute }, set: { form.audio = $0 ? .original : .mute }),
                    options: [(true, String(localized: "Generate")), (false, String(localized: "Silent"))])
            } else {
                SectionLabel(title: "Audio", detail: form.audioDetail)
                SegmentedControl(selection: $form.audio, options: form.audioChoices.map { ($0, $0.title) })
            }
        }
    }

    private var draftLengthSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Draft length", detail: form.draftLengthDetail(in: context))
            SegmentedControl(selection: $form.draftLength) { $0.title }
        }
    }
}

// MARK: Mode, task and the images' roles

extension CreatePanel {
    private var modePicker: some View {
        SegmentedControl(
            selection: Binding(get: { form.tab }, set: { tab in recheckRoles { $0.tab = tab } }),
            options: form.modeChoices.map { ($0, $0.shortTitle) })
    }

    /// Motion transfer, Edit or Extend, for a model that does more than one (Seedance).
    @ViewBuilder private var taskPicker: some View {
        let tasks = form.taskChoices(in: context)
        if tasks.count > 1 {
            SegmentedControl(
                selection: Binding(get: { form.mode }, set: { task in recheckRoles { $0.pickTask(task) } }),
                options: tasks.map { ($0, $0.title) })
        }
    }

    /// Applies a change of model, tab or task and says what it did to the images' roles. One that removes images goes
    /// through `replaceDraft`, so the toast offers them back.
    private func recheckRoles(_ change: (inout CreateForm) -> Void) {
        var changed = form
        let note = changed.recheckingRoles(change)
        if changed.dropsInputs(of: form) {
            navigation.replaceDraft { $0 = changed }
        } else {
            form = changed
        }
        roleChange = note
    }
}

extension CreatePanel {
    /// Several results of the same request from one submit, on one line; held at 1, with the reason under it, where
    /// the jobs make one.
    private var variantsSection: some View {
        let reason = form.variantsUnavailableReason(in: context)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(
                    title: "Variants", detail: reason == nil ? String(localized: "billed each") : nil
                )
                ValueStepper(
                    label: String(localized: "Variants"),
                    value: Binding(get: { form.variants(in: context) }, set: { form.variants = $0 }),
                    range: CreateForm.variantChoices, buttonSize: 22
                )
                // Until the connection's capabilities are read, the jobs make one.
                .disabled(reason != nil || context.capabilities == nil)
                .hoverHint("Number of variants")
            }
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

private struct SubmitBar: View {
    let form: CreateForm
    let context: CreateContext
    let isSubmitting: Bool
    let onSubmit: (Bool) -> Void
    @StoredShortcut(.generate) private var generateShortcut

    var body: some View {
        let state = SubmitBarState(form: form, in: context)
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let blocker = state.draftBlocker ?? state.generateBlocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            } else if let line = state.costLine {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text(line.detail)
                        .font(.caption)
                        .foregroundStyle(line.isWarning ? Theme.warning : Theme.faint)
                }
            }
            // Credit prices and batch counts can outgrow a narrow panel; the main button then gets a row of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) { buttons(state) }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) { buttons(state) }
            }
            .disabled(isSubmitting)
        }
    }

    /// A batch runs as drafts by default: Draft becomes the main button. A model without drafts has Generate only.
    @ViewBuilder private func buttons(_ state: SubmitBarState) -> some View {
        if !form.offersDraft {
            primaryButton(title: form.generateButtonTitle, isDraft: false, state: state)
        } else if form.isBatch {
            secondaryButton(title: form.generateButtonTitle, isDraft: false, state: state)
            primaryButton(title: form.draftButtonTitle, isDraft: true, state: state)
        } else {
            secondaryButton(title: form.draftButtonTitle, isDraft: true, state: state)
            primaryButton(title: form.generateButtonTitle, isDraft: false, state: state)
        }
    }

    /// Keeps its natural width; the primary button takes the rest of the row.
    private func secondaryButton(title: String, isDraft: Bool, state: SubmitBarState) -> some View {
        Button {
            onSubmit(isDraft)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let price = state.price(isDraft: isDraft) {
                    Text(price)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .buttonStyle(.secondaryAction)
        .disabled(state.blocker(isDraft: isDraft) != nil)
        .fixedSize()
    }

    private func primaryButton(title: String, isDraft: Bool, state: SubmitBarState) -> some View {
        Button {
            onSubmit(isDraft)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(title)
                if let price = state.price(isDraft: isDraft) {
                    PriceTag(text: price)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.primaryAction)
        .keyboardShortcut(generateShortcut)
        .disabled(state.blocker(isDraft: isDraft) != nil)
    }
}
