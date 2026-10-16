import JutsuCore
import Presentation
import SwiftUI

/// Create Character's form, top to bottom: presets, a person or an animal and its look, a description, then the
/// face, style references, Randomize and the number of sheets as compact rows, and last the tier's traits, one
/// collapsed row per group that opens to its chips. Everything it sets lives in `CharacterBuilder`, so it stays for
/// the next time the sheet opens.
struct CreateCharacterForm: View {
    private enum ImageSlot {
        case face
        case styles
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the open file panel picks for; one panel serves both, as two importers on one view don't both open.
    @State private var isPicking = false
    @State private var slot = ImageSlot.face
    @State private var presets: PagedFeed<CharacterPreset>?
    /// The trait group showing its chips; one at a time.
    @State private var openGroup: String?

    private var builder: CharacterBuilder { environment.characterBuilder }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            presetsSection
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(title: "Character")
                HStack(spacing: Theme.Spacing.small) {
                    SegmentedControl(
                        selection: Binding(get: { builder.kind }, set: { builder.selectKind($0) }),
                        title: \.title
                    )
                    .fixedSize()
                    if builder.kind.tiers.count > 1 {
                        FilterMenu(
                            title: String(localized: "Look"),
                            selection: Binding(get: { builder.tier }, set: { builder.selectTier($0) }),
                            options: builder.kind.tiers.map { ($0, $0.title) })
                    }
                }
            }
            descriptionSection
            optionsSection
            traitsSection
        }
        .task(id: environment.providerGeneration) {
            presets = environment.characterPresetsFeed()
            await presets?.loadIfNeeded()
        }
        .fileImporter(
            isPresented: $isPicking, allowedContentTypes: [.image], allowsMultipleSelection: slot == .styles
        ) { result in
            guard case .success(let urls) = result else { return }
            let images = ReferencesSection.references(urls)
            switch slot {
            case .face: builder.face = images.first ?? builder.face
            case .styles: builder.addStyles(images)
            }
        }
    }

    /// Ready-made characters: a click fills the form with one.
    @ViewBuilder private var presetsSection: some View {
        if let presets, !presets.items.isEmpty || presets.hasMore {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack {
                    SectionLabel(title: "Presets")
                    if builder.preset != nil {
                        Button("Clear Preset") { builder.clearPreset() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .pointerCursor()
                    }
                }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Theme.Spacing.small) {
                        ForEach(presets.items) { preset in
                            PresetTile(preset: preset, isPicked: builder.preset?.id == preset.id) {
                                builder.apply(preset)
                            }
                        }
                        if presets.hasMore && presets.failure == nil {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 40)
                                .task(id: presets.items.count) { await presets.loadMore() }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(
                title: "Description",
                detail: builder.brief.isEmpty ? nil : "\(builder.brief.count) / 4000")
            TextEditor(text: Binding(get: { builder.brief }, set: { builder.brief = $0 }))
                .font(.body)
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.small)
                .frame(minHeight: 90, maxHeight: 160)
                .well()
                .overlay(alignment: .topLeading) {
                    if builder.brief.isEmpty {
                        Text("Who they are, how they look and dress")
                            .font(.body)
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, Theme.Spacing.small + 5)
                            .padding(.vertical, Theme.Spacing.small)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Description")
        }
    }

    /// The face to keep, up to three style references, Randomize and the number of sheets.
    private var optionsSection: some View {
        VStack(spacing: 0) {
            OptionRow(
                title: "Face", detail: String(localized: "Optional · a photo of the face to keep")
            ) {
                if let face = builder.face {
                    RemovableThumb(image: face) { builder.face = nil }
                } else {
                    Button("Choose…") { pick(.face) }
                        .buttonStyle(.secondaryAction)
                        .controlSize(.small)
                        .accessibilityLabel("Choose a face")
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let image = ReferencesSection.references(ReferencesSection.images(urls)).first else {
                    return false
                }
                builder.face = image
                return true
            }
            Divider()
            OptionRow(
                title: "Style",
                detail: String(localized: "Optional · up to 3 images of the look to follow")
            ) {
                HStack(spacing: 6) {
                    ForEach(Array(builder.styles.enumerated()), id: \.offset) { index, style in
                        RemovableThumb(image: style) { builder.removeStyle(at: index) }
                    }
                    if builder.styles.count < CharacterDesign.maxStyles {
                        Button("Choose…") { pick(.styles) }
                            .buttonStyle(.secondaryAction)
                            .controlSize(.small)
                            .accessibilityLabel("Choose style images")
                    }
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                let images = ReferencesSection.references(ReferencesSection.images(urls))
                return builder.addStyles(images) < images.count
            }
            Divider()
            OptionRow(
                title: "Randomize",
                detail: String(localized: "Fills in what the form leaves open differently each time")
            ) {
                Toggle("Randomize", isOn: Binding(get: { builder.randomize }, set: { builder.randomize = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Divider()
            OptionRow(title: "Sheets") {
                SegmentedControl(
                    selection: Binding(get: { builder.count }, set: { builder.count = $0 }),
                    options: CharacterDesign.sheetCounts.map { ($0, "\($0)") }
                )
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .well()
    }

    /// The tier's trait groups, each a collapsed row with its choice; a click opens its chips under it.
    @ViewBuilder private var traitsSection: some View {
        if builder.traitsFailure != nil || !builder.traitGroups.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(title: "Traits", detail: traitsDetail)
                if let failure = builder.traitsFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                if !builder.traitGroups.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(builder.traitGroups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { Divider() }
                            traitRow(group)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .well()
                }
            }
        }
    }

    /// "3 picked · the rest random", "Any", or `nil` with nothing picked and nothing random.
    private var traitsDetail: String? {
        let picked = builder.traits.values.map(\.count).reduce(0, +)
        switch (picked, builder.randomize) {
        case (0, true): return String(localized: "Random")
        case (0, false): return nil
        case (_, true): return String(localized: "\(picked) picked · the rest random")
        case (_, false): return String(localized: "\(picked) picked")
        }
    }

    private func traitRow(_ group: CharacterTraitGroup) -> some View {
        let isOpen = openGroup == group.id
        return TraitGroupRow(
            group: group, picked: pickedTitles(in: group), randomize: builder.randomize, isOpen: isOpen
        ) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                openGroup = isOpen ? nil : group.id
            }
        } chips: {
            FlowLayout(spacing: 6) {
                ForEach(group.traits) { trait in
                    TraitChip(title: trait.title, isPicked: builder.isPicked(trait, in: group)) {
                        builder.toggle(trait, in: group)
                    }
                }
            }
        }
    }

    /// The group's picks in the order they were made.
    private func pickedTitles(in group: CharacterTraitGroup) -> [String] {
        (builder.traits[group.id] ?? []).compactMap { id in group.traits.first { $0.id == id }?.title }
    }

    private func pick(_ slot: ImageSlot) {
        self.slot = slot
        isPicking = true
    }
}

/// A trait group on one line: its name, what's picked or "Any" ("Random" with Randomize on), and its limit. A click
/// shows its chips under it.
private struct TraitGroupRow<Chips: View>: View {
    let group: CharacterTraitGroup
    let picked: [String]
    let randomize: Bool
    let isOpen: Bool
    let onToggle: () -> Void
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(group.title)
                        .font(.callout)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: Theme.Spacing.small)
                    choice
                    if group.maxPicks > 1 {
                        Text("up to \(group.maxPicks)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel(group.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(isOpen ? Text("Hides the choices") : Text("Shows the choices"))
            if isOpen {
                chips()
                    .padding(.bottom, Theme.Spacing.medium)
            }
        }
    }

    @ViewBuilder private var choice: some View {
        if !picked.isEmpty {
            Text(picked.joined(separator: ", "))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if randomize {
            Label("Random", systemImage: "dice")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        } else {
            Text("Any")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
    }

    private var accessibilityValue: String {
        let choice =
            picked.isEmpty
            ? (randomize ? String(localized: "Random") : String(localized: "Any")) : picked.joined(separator: ", ")
        return group.maxPicks > 1 ? String(localized: "\(choice), up to \(group.maxPicks)") : choice
    }
}

/// A preset's picture and name; lime-rimmed when it fills the form.
private struct PresetTile: View {
    let preset: CharacterPreset
    let isPicked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Theme.well
                    .frame(width: 84, height: 84)
                    .overlay { RemoteThumbnail(url: preset.previewURL, maxPixelSize: 240) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(isPicked ? Theme.accent : Theme.stroke, lineWidth: isPicked ? 2 : 1)
                    }
                Text(preset.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPicked ? Theme.accent : Theme.muted)
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(preset.settings == nil)
        .help(preset.unavailableReason ?? preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
    }
}

/// A trait to pick: a capsule, filled lime once picked.
private struct TraitChip: View {
    let title: String
    let isPicked: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isPicked ? .bold : .semibold))
                .foregroundStyle(isPicked ? Theme.ink : (isHovered ? Theme.text : Theme.muted))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(isPicked ? Theme.accent : (isHovered ? Theme.glassHover : Theme.well), in: Capsule())
                .overlay { Capsule().strokeBorder(isPicked ? Color.clear : Theme.stroke, lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
    }
}
