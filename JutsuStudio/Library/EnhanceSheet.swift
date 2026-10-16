import JutsuCore
import Presentation
import SwiftUI

/// The options and the price of one operation of the Enhance menu. Nothing is queued without a price on screen:
/// the quote, or, where there is none (Topaz), "Price shown after the run" and the user's explicit agreement to it.
struct EnhanceSheet: View {
    let item: LibraryItemModel
    let kind: PostAction.Kind

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var upscale = UpscaleOptions()
    @State private var aspect = ReframeAspect.portrait
    @State private var language = DubLanguage.english
    @State private var voice: VoiceChoice?
    /// The provider's price for the current options; `nil` while it is asked for or when it can't be had.
    @State private var price: Cost?
    @State private var isPricing = true
    @State private var acceptsUnknownPrice = false
    /// The result file's own length and size, read once.
    @State private var probed: SourceVideo?
    /// The size of the result's first frame, once the reframe preview has it.
    @State private var frameSize: PixelSize?
    @State private var submitting = SubmitController()
    @State private var message: UserMessage?

    /// - Parameter action: the options to open with; `nil` for the defaults.
    init(item: LibraryItemModel, kind: PostAction.Kind, action: PostAction?) {
        self.item = item
        self.kind = kind
        switch action {
        case .upscale(let options)?: _upscale = State(initialValue: options)
        case .reframe(let aspect)?: _aspect = State(initialValue: aspect)
        case .dub(let language)?: _language = State(initialValue: language)
        case .changeVoice(let voice)?: _voice = State(initialValue: voice)
        case .removeBackground?, nil: break
        }
    }

    /// `nil` until Change Voice has a voice.
    private var action: PostAction? {
        switch kind {
        case .upscale: .upscale(upscale)
        case .reframe: .reframe(aspect)
        case .removeBackground: .removeBackground
        case .dub: .dub(language)
        case .changeVoice: voice.map(PostAction.changeVoice)
        }
    }

    private var spec: JobSpec? {
        action.flatMap {
            item.job.operationSpec(
                $0, owner: environment.provider?.owner, duration: probed?.duration, pixelSize: probed?.pixelSize)
        }
    }

    /// The canvas Reframe would make, from the first frame's size or else the probed file's.
    private var canvas: ReframeCanvas? {
        (frameSize ?? probed?.pixelSize).flatMap { ReframeCanvas(source: $0, aspect: aspect) }
    }

    private var isTooLongToReframe: Bool {
        (probed?.duration ?? item.job.outputDuration) > ReframeAspect.maxSourceLength
    }

    private var canQueue: Bool {
        guard spec != nil, let price, !submitting.isBusy, connection.state.isConnected else { return false }
        // A canvas of the result's own shape has nothing to fill in.
        if kind == .reframe, canvas?.isUnchanged == true { return false }
        return price != .unknownCredits || acceptsUnknownPrice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action?.title ?? kind.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(item.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            options
            priceLine
            actions
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .task { await probe() }
        .task(id: spec) { await quote() }
        .submitConfirmation(submitting, confirmTitle: String(localized: "Start Anyway"))
        .alert(message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    @ViewBuilder private var options: some View {
        switch kind {
        case .upscale:
            SectionLabel(title: "Engine")
            SegmentedControl(selection: $upscale.engine, options: UpscaleEngine.allCases.map { ($0, $0.title) })
                .onChange(of: upscale.engine) { _, engine in
                    // Topaz has no 2K; its next target up is 4K.
                    if !engine.targets.contains(upscale.target) { upscale.target = .k4 }
                }
            SectionLabel(title: "Target")
            SegmentedControl(selection: $upscale.target, options: upscale.engine.targets.map { ($0, $0.title) })
            if upscale.engine.takesFrameRate {
                SectionLabel(title: "Frame rate")
                SegmentedControl(
                    selection: $upscale.frameRate, options: UpscaleFrameRate.offered.map { ($0, $0.title) })
                Text("60 fps costs twice as much.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        case .reframe:
            SectionLabel(title: "Canvas")
            SegmentedControl(selection: $aspect, options: ReframeAspect.allCases.map { ($0, $0.rawValue) })
            ReframePreview(url: item.outputFile, canvas: canvas, frameSize: $frameSize)
            if isTooLongToReframe {
                Text("Reframe takes results up to a minute long.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }
        case .dub:
            SectionLabel(title: "Language")
            Picker(String(localized: "Language"), selection: $language) {
                ForEach(DubLanguage.sorted(), id: \.self) { Text($0.title()).tag($0) }
            }
            .labelsHidden()
            Text("The speech is translated and lip-synced; the picture stays as it is.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        case .changeVoice:
            SectionLabel(title: "Voice")
            VoicePicker(selection: $voice)
        case .removeBackground:
            Text(PostOperationText.removeBackgroundNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var priceLine: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if action == nil {
                Text("Pick a voice to see the price.")
            } else if isPricing {
                Text("Asking Higgsfield for the price…")
            } else if let price {
                Text(PostOperationText.price(price, for: action))
                if price == .unknownCredits {
                    Toggle(PostOperationText.unknownPriceConsent, isOn: $acceptsUnknownPrice)
                        .toggleStyle(.checkbox)
                }
            } else {
                Text("Higgsfield gave no price for this, so it can't be queued.")
            }
            Text("The result is added to the Library, linked to this one.")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            if submitting.isBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: Theme.Spacing.small)
            Button("Cancel") { dismiss() }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button {
                queue()
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Label(action?.title ?? kind.title, systemImage: "wand.and.rays")
                    if let price, price != .unknownCredits { PriceTag(text: LibraryFormat.cost(price)) }
                }
            }
            .buttonStyle(.primaryAction)
            .keyboardShortcut(.defaultAction)
            .disabled(!canQueue)
        }
    }

    // MARK: Actions

    private func probe() async {
        guard let url = item.outputFile else { return }
        probed = try? await AppEnvironment.probeSource(url, bookmark: nil)
    }

    private func quote() async {
        isPricing = true
        acceptsUnknownPrice = false
        defer { isPricing = false }
        price = nil
        guard let spec else { return }
        price = await environment.estimate(spec)
    }

    /// An unknown price goes to the cap check as unknown, so under a cap it asks first, as Create does.
    private func queue() {
        guard let spec, let price else { return }
        let known = price == .unknownCredits ? nil : price
        let submitting = submitting
        submitting.run {
            await submitting.handle(
                await environment.submitDecision(for: spec, cost: known),
                blocked: { message = UserMessage(title: String(localized: "Can't queue this"), message: $0) }
            ) { _, approved in
                await enqueue(spec, overCapApproved: approved)
            }
        }
    }

    private func enqueue(_ spec: JobSpec, overCapApproved: Bool = false) async {
        let error = await pipeline.enqueue([spec], parentID: item.id, overCapApproved: overCapApproved)
        if let error { message = error } else { dismiss() }
    }

    private var pipeline: SubmitPipeline {
        SubmitPipeline(environment: environment, connection: connection)
    }
}
