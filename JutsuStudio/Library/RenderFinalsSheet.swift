import JutsuCore
import Presentation
import SwiftUI

/// Render finals for a batch's starred drafts: one resolution for all, their combined price and one spend-cap check
/// for the total. Each final links to its draft, as Render final on a result's page does.
struct RenderFinalsSheet: View {
    let batch: LibraryBatch

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @Environment(LiveJobs.self) private var liveJobs
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var resolution: Resolution
    /// An account's estimates of the finals, by price key; an API key prices them from the list.
    @State private var estimates: [JobSpec: Cost] = [:]
    @State private var pricing = try? Pricing.bundled()
    @State private var submitting = SubmitController()
    @State private var message: UserMessage?

    init(batch: LibraryBatch) {
        self.batch = batch
        _resolution = State(initialValue: BatchFinals(batch).resolutions.first ?? .p720)
    }

    private var drafts: BatchFinals { BatchFinals(batch) }

    /// The finals to queue: those of the starred drafts not already in the queue at this resolution.
    private var finals: [BatchFinals.Final] {
        drafts.finals(at: resolution, owner: environment.provider?.owner) { spec, parentID in
            liveJobs.activeJob(parentID: parentID, spec: spec) != nil
        }
    }

    private var quote: FinalsQuote {
        FinalsQuote(specs: finals.map(\.spec.priceKey), kind: connection.state.kind)
    }

    private var price: Cost? {
        let finals = finals
        return BatchFinals.listPrice(of: finals, pricing: pricing, connection: connection.state.kind)
            ?? BatchFinals.total(finals.map { estimates[$0.spec.priceKey] })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Render finals for starred")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(batch.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            resolutionPicker
            summary
            actions
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.background)
        .task(id: quote) { await estimate(quote) }
        .submitConfirmation(submitting, confirmTitle: String(localized: "Render Anyway"))
        .alert(message?.title ?? "", isPresented: Binding(isPresenting: $message), presenting: message) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message.message)
        }
    }

    @ViewBuilder private var resolutionPicker: some View {
        let options = drafts.resolutions
        let model = drafts.model ?? .genjutsu
        // One option needs no picker; the label names it (a Kling draft's final is Pro).
        SectionLabel(
            title: "Resolution", detail: options.count == 1 ? options[0].title(on: model) : nil)
        if options.count > 1 {
            SegmentedControl(selection: $resolution, options: options.map { ($0, $0.title(on: model)) })
        }
    }

    @ViewBuilder private var summary: some View {
        let queued = drafts.drafts.count - finals.count
        VStack(alignment: .leading, spacing: 4) {
            Text("Each final keeps its draft's inputs and is linked to it.")
            if queued > 0 {
                Text("Leaves out \(queued) already in the Queue.")
            }
            if !connection.state.isConnected {
                Text("Connect Higgsfield in Settings")
            }
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
            if finals.isEmpty {
                Button(QueuedNotice.viewInQueue) {
                    navigation.selection = .queue
                    dismiss()
                }
                .buttonStyle(.primaryAction)
            } else {
                Button {
                    render()
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Label(BatchFinals.title(count: finals.count), systemImage: "sparkles")
                        if let price { PriceTag(text: LibraryFormat.cost(price)) }
                    }
                }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting.isBusy || !connection.state.isConnected)
            }
        }
    }

    // MARK: Actions

    /// One cap check for the total of all the finals, as Create does for a batch.
    private func render() {
        let (finals, price, submitting) = (finals, price, submitting)
        submitting.run {
            await submitting.handle(
                await environment.submitDecision(for: finals.map(\.spec), cost: price),
                blocked: { message = UserMessage(title: String(localized: "Can't queue the finals"), message: $0) }
            ) { _, approved in
                // Taken again once the user agrees, so a final queued while the question was up is left out.
                await enqueue(approved ? self.finals : finals, overCapApproved: approved)
            }
        }
    }

    /// Several finals share a batch of their own, so the Queue and the Library keep them together.
    /// - Parameter overCapApproved: the user confirmed going over today's cap.
    private func enqueue(_ finals: [BatchFinals.Final], overCapApproved: Bool = false) async {
        let error = await pipeline.enqueue(
            linked: finals.map { ($0.spec, $0.parentID) }, batchID: finals.count > 1 ? UUID() : nil,
            overCapApproved: overCapApproved)
        if let error { message = error } else { dismiss() }
    }

    private var pipeline: SubmitPipeline {
        SubmitPipeline(environment: environment, connection: connection)
    }

    /// An account's estimate of each final, asked for all at once.
    private func estimate(_ quote: FinalsQuote) async {
        estimates = [:]
        guard quote.kind == .account else { return }
        let environment = environment
        estimates = await EstimateCache.estimate(quote.specs) { spec in await environment.estimate(spec) }
    }
}

private struct FinalsQuote: Hashable {
    let specs: [JobSpec]
    let kind: ProviderKind?
}
