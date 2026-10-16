import JutsuCore
import Presentation
import SwiftUI

/// Generate…'s form: the prompt, then the model, frame, variants and image to edit as compact rows.
struct GenerateReferenceForm: View {
    let source: PixelSize?
    let mode: Mode
    /// The prompt takes the height the parent has to spare, as on Create's Image side; a sheet keeps it bounded.
    var fillsHeight = false

    @Environment(AppEnvironment.self) private var environment
    @State private var isPickingInput = false

    private var generator: ReferenceGenerator { environment.referenceGenerator }

    var body: some View {
        @Bindable var generator = generator
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    SectionLabel(title: "Prompt")
                    if !generator.prompt.isEmpty {
                        PromptClearButton { generator.prompt = "" }
                    }
                }
                TextEditor(text: $generator.prompt)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.small)
                    // A fixed ideal height: the editor would otherwise ask for its whole text, and the Image panel
                    // would drop to its scrolling layout with a short editor once the prompt gets long.
                    .frame(minHeight: 160, idealHeight: 160, maxHeight: fillsHeight ? .infinity : 280)
                    .well()
                    .accessibilityLabel("Prompt")
            }
            if generator.model == nil {
                optionSkeleton
            } else {
                options
            }
        }
        .fileImporter(isPresented: $isPickingInput, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            generator.inputImage = ReferencesSection.references([url]).first
        }
    }

    /// The rows' places while the connection's first list of models loads; the prompt can be written meanwhile.
    private var optionSkeleton: some View {
        VStack(spacing: 0) {
            OptionRow(title: "Model") { SkeletonCapsule(width: 180) }
            Divider()
            OptionRow(title: "Frame") { SkeletonCapsule(width: 90) }
            Divider()
            OptionRow(title: "Variants") { SkeletonCapsule(width: 150) }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .well()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading image models")
    }

    private var options: some View {
        @Bindable var generator = generator
        return VStack(spacing: 0) {
            OptionRow(title: "Model") {
                FilterMenu(
                    title: String(localized: "Model"),
                    selection: Binding(get: { generator.modelID ?? "" }, set: { generator.selectModel($0) }),
                    options: generator.models.map { ($0.id, Self.title(of: $0)) })
            }
            Divider()
            OptionRow(title: "Frame") {
                FilterMenu(
                    title: String(localized: "Frame"),
                    selection: Binding(
                        get: { generator.aspectRatio(source: source, mode: mode) ?? "" },
                        set: { generator.chosenAspectRatio = $0 }),
                    options: (generator.model?.aspectRatios ?? []).map { ($0, $0) })
            }
            if let model = generator.model, model.variantCounts.count > 1 {
                Divider()
                OptionRow(title: "Variants") {
                    SegmentedControl(
                        selection: $generator.count, options: model.variantCounts.map { ($0, "\($0)") }
                    )
                    .fixedSize()
                }
            }
            if let model = generator.model, model.input != .none {
                Divider()
                inputRow(model)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .well()
    }

    /// The image an edit model changes: optional for some models, required for others. Drop one on the row or
    /// choose it.
    private func inputRow(_ model: ImageModel) -> some View {
        OptionRow(
            title: "Image to edit",
            detail: model.input == .required ? String(localized: "Required") : String(localized: "Optional")
        ) {
            if let input = generator.inputImage {
                RemovableThumb(image: input) { generator.inputImage = nil }
            } else {
                Button("Choose…") { isPickingInput = true }
                    .buttonStyle(.secondaryAction)
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let image = ReferencesSection.references(ReferencesSection.images(urls)).first else { return false }
            generator.inputImage = image
            return true
        }
    }

    /// "Soul 2 · $0.0032 an image".
    private static func title(of model: ImageModel) -> String {
        guard let price = model.listPrice else { return model.title }
        return String(localized: "\(model.title) · \(CostText.imagePrice(price)) an image")
    }
}

/// A control's place while it loads: a capsule that breathes, still under Reduce Motion.
private struct SkeletonCapsule: View {
    let width: CGFloat
    @State private var isDim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Theme.glass)
            .frame(width: width, height: 34)
            .animation(.easeInOut(duration: 0.9).repeatForever()) { $0.opacity(isDim ? 0.45 : 1) }
            .onAppear { isDim = !reduceMotion }
    }
}
