import JutsuCore
import Presentation
import SwiftUI

/// The Image side of Create: Generate…'s form on the left, filling its frame; the requests and results on the right,
/// shown once: a running request as a spinner with Cancel until its images arrive, then the picked image large over
/// a strip of the results. The form, runs and results are `ReferenceGenerator`'s own, shared with the References
/// quick action, so a request keeps going while the side or the page changes, and every image is saved to
/// Library › Images as it arrives.
struct CreateImageSide: View {
    let controller: ImageGenerateController

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            CreateImagePanel(controller: controller)
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 380)
            CreateImageStage(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }
}

/// The form and Generate with its price. The prompt takes the height the frame has to spare, with Generate at the
/// bottom; a window too short for the form scrolls it instead.
private struct CreateImagePanel: View {
    let controller: ImageGenerateController

    @Environment(AppEnvironment.self) private var environment

    private var generator: ReferenceGenerator { environment.referenceGenerator }

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel(fillsHeight: true)
            ScrollView { panel(fillsHeight: false) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
        .task(id: generator.priceKey(source: controller.source, mode: controller.mode)) {
            await controller.refreshPrice(environment: environment)
        }
        .imageGenerateDialogs(controller, environment: environment)
    }

    private func panel(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            formSection(fillsHeight: fillsHeight)
                .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
            generateSection
        }
        .padding(Theme.Spacing.large)
    }

    @ViewBuilder private func formSection(fillsHeight: Bool) -> some View {
        if let reason = generator.unavailableReason, generator.models.isEmpty {
            Label(reason, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(Theme.muted)
        } else {
            GenerateReferenceForm(source: controller.source, mode: controller.mode, fillsHeight: fillsHeight)
        }
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ImageGenerateNotice()
            Button {
                controller.generate(environment: environment)
            } label: {
                GenerateButtonLabel(
                    isGenerating: controller.isGenerating(generator), price: controller.buttonPrice(generator)
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primaryAction)
            .disabled(!controller.canGenerate(generator))
            .hoverHint(generator.price.map(ReferenceGenerator.priceText) ?? "")
        }
    }
}

/// The right side: the picked result large (the newest without a pick) over a strip of the results, with the
/// requests that are running or didn't finish. Before a request's first image arrives, it is a spinner with Cancel
/// in the middle, not also a row and placeholders.
private struct CreateImageStage: View {
    let controller: ImageGenerateController

    @Environment(AppEnvironment.self) private var environment

    private var generator: ReferenceGenerator { environment.referenceGenerator }

    private var current: GeneratedImage? {
        controller.selected.flatMap { id in generator.images.first { $0.id == id } } ?? generator.images.first
    }

    /// A finished request shows as its images; a running, failed or canceled one keeps its row.
    private var runs: [ImageRun] { generator.runs.filter { $0.state != .finished } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            UnsavedRecordsWarning()
            if let image = current {
                RemoteThumbnail(url: image.url, maxPixelSize: 2048, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityLabel(image.prompt)
                Text(image.prompt)
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .textSelection(.enabled)
                ForEach(runs) { run in
                    ImageRunRow(run: run) { generator.cancel(run.id) }
                }
                strip
            } else if let running = runs.first(where: { $0.state == .running }) {
                VStack(spacing: Theme.Spacing.medium) {
                    ProgressView()
                        .controlSize(.large)
                    Text(running.title)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    Button("Cancel") { generator.cancel(running.id) }
                        .buttonStyle(.secondaryAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(runs) { run in
                    ImageRunRow(run: run) { generator.cancel(run.id) }
                }
                EmptyState(systemImage: "photo", title: "No images yet")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The results, newest first, after the places of the images running requests will make.
    private var strip: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: Theme.Spacing.small) {
                    ForEach(0..<pendingCount, id: \.self) { _ in
                        PendingTile()
                            .frame(width: 72, height: 72)
                    }
                    ForEach(generator.images) { image in
                        ImageStripTile(
                            image: image, isSelected: current?.id == image.id,
                            onSelect: { controller.selected = image.id },
                            onDelete: { controller.delete(image.id, environment: environment) })
                    }
                }
            }
            .scrollIndicators(.never)
            Button("Clear") {
                controller.selected = nil
                generator.clearResults()
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .semibold))
            .hoverHint(String(localized: "Take the results off this list. They stay in Library › Images."))
        }
        .frame(height: 72)
    }

    private var pendingCount: Int {
        runs.filter { $0.state == .running }.map(\.count).reduce(0, +)
    }
}

/// One generated image in the strip under the large one: a click shows it large, the trash button moves it to the
/// Trash, also out of Library › Images.
private struct ImageStripTile: View {
    let image: GeneratedImage
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Theme.well
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteThumbnail(url: image.url, maxPixelSize: 480) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isHovered && !image.isPicked {
                    TileButton(systemImage: "trash", help: String(localized: "Move to Trash"), action: onDelete)
                        .padding(3)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
            .pointerCursor()
            .hoverHint(image.prompt)
            .accessibilityElement()
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(image.prompt)
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: String(localized: "Move to Trash")) { if !image.isPicked { onDelete() } }
    }
}

/// What Generate's button can't say: why it is off, a price known only after the run, or why there's no quote.
struct ImageGenerateNotice: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let generator = environment.referenceGenerator
        if let blocker = generator.blocker, generator.model != nil {
            Text(blocker)
                .font(.callout)
                .foregroundStyle(Theme.muted)
        } else if generator.price == .unknownCredits {
            Text(ReferenceGenerator.priceText(.unknownCredits))
                .font(.callout)
                .foregroundStyle(Theme.muted)
        } else if let failure = generator.priceFailure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
        }
    }
}

/// Generate for one Generate… form, shared by the Image side of Create and the References quick-action sheet: the
/// price, the cap question, failures and the result shown large. The request itself is `ReferenceGenerator`'s.
@MainActor
@Observable
final class ImageGenerateController {
    /// The source clip's size, for the default frame; `nil` without a source, as on the Image side.
    let source: PixelSize?
    /// The video mode the images are for; the Image side has none and makes them as for Motion.
    let mode: Mode
    var confirmation: CapConfirmation?
    var failure: UserMessage?
    private(set) var isStarting = false
    /// The result shown large; `nil` follows the newest.
    var selected: UUID?

    init(source: PixelSize? = nil, mode: Mode = .motionTransfer) {
        self.source = source
        self.mode = mode
    }

    /// A request is being started or runs.
    func isGenerating(_ generator: ReferenceGenerator) -> Bool { isStarting || generator.isRunning }

    func canGenerate(_ generator: ReferenceGenerator) -> Bool {
        generator.blocker == nil && !isGenerating(generator)
    }

    /// The price for the request, quoted or estimated; none when the price is only known after the run.
    func buttonPrice(_ generator: ReferenceGenerator) -> String? {
        guard let price = generator.price, price != .unknownCredits else { return nil }
        return CostText.imagePrice(price)
    }

    /// A quick stop on each change: typing the prompt doesn't ask for a price on every key.
    func refreshPrice(environment: AppEnvironment) async {
        guard let provider = environment.imageProvider else { return }
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return
        }
        await environment.referenceGenerator.refreshPrice(
            provider: provider, source: source, mode: mode, upload: environment.imageUploader(provider))
    }

    /// The generator asks first when the price takes today past the cap, or isn't known under one.
    func generate(environment: AppEnvironment, overCapApproved: Bool = false) {
        let generator = environment.referenceGenerator
        guard canGenerate(generator) else { return }
        guard let provider = environment.imageProvider else {
            failure = UserMessage(
                title: String(localized: "Not connected"),
                message: String(localized: "Connect Higgsfield again to generate images."))
            return
        }
        isStarting = true
        Task {
            defer { isStarting = false }
            let started = await generator.generate(
                provider: provider, source: source, mode: mode, price: generator.price ?? generator.listPrice,
                overCapApproved: overCapApproved, upload: environment.imageUploader(provider))
            if case .needsConfirmation(let question) = started { confirmation = question }
        }
    }

    /// Takes a result off the list and moves its saved copy to the Trash, also out of Library › Images.
    /// Higgsfield keeps its copy: neither of its APIs deletes a generation.
    func delete(_ id: UUID, environment: AppEnvironment) {
        if selected == id { selected = nil }
        guard environment.referenceGenerator.remove(id) != nil else { return }
        Task {
            do {
                try await environment.imageLibrary.trash([id])
            } catch {
                failure = UserMessage(
                    title: String(localized: "Couldn't move the image to the Trash"),
                    message: error.localizedDescription)
            }
        }
    }
}

extension View {
    /// The cap question and the failure alert of `controller`'s Generate.
    func imageGenerateDialogs(_ controller: ImageGenerateController, environment: AppEnvironment) -> some View {
        @Bindable var controller = controller
        return
            self
            .confirmationDialog(
                controller.confirmation?.title ?? "", isPresented: Binding(isPresenting: $controller.confirmation),
                presenting: controller.confirmation
            ) { confirmation in
                Button(confirmation.confirmTitle) {
                    controller.generate(environment: environment, overCapApproved: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
            .alert(
                controller.failure?.title ?? "", isPresented: Binding(isPresenting: $controller.failure),
                presenting: controller.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message.message)
            }
    }
}
