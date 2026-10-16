import JutsuCore
import Presentation
import SwiftUI

/// "Render final" box on a result's page: resolution picker, price and the draft→final quote. A native Seedance draft
/// of the signed-in account also shows its seven-day finalize window, and its 1080p final is Higgsfield's finalize.
/// Owns the quote task so `LibraryDetail` doesn't.
struct RenderFinalSection: View {
    let item: LibraryItemModel
    @Binding var finalResolution: Resolution
    @Binding var estimatedFinal: Cost?
    let pricing: Pricing?
    let kind: ProviderKind?
    let provider: (any GenerationProvider)?
    /// The signed-in account, whose native drafts finalize at 1080p.
    let owner: String?
    let isWorking: Bool
    let isConnected: Bool
    /// Called with the price shown on the button, which the spend-cap check uses.
    let onRender: (Cost?) -> Void

    @Environment(LiveJobs.self) private var liveJobs
    @Environment(NavigationModel.self) private var navigation

    private var finalPrice: Cost? {
        item.finalPrice(at: finalResolution, pricing: pricing, connection: kind) ?? estimatedFinal
    }

    /// The final at the picked resolution while it is still in the queue: rendering it again would charge twice.
    private var queuedFinal: Job? {
        liveJobs.activeJob(parentID: item.id, spec: finalSpec)
    }

    private var finalSpec: JobSpec { item.finalSpec(at: finalResolution, owner: owner) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            let options = item.finalResolutions
            // One option needs no picker; the label names it (a Kling draft's final is Pro).
            SectionLabel(
                title: "Render final",
                detail: options.count == 1 ? options[0].title(on: item.spec.model) : nil)
            if options.count > 1 {
                SegmentedControl(
                    selection: $finalResolution, options: options.map { ($0, $0.title(on: item.spec.model)) })
            }
            if let deadline = item.job.finalizeDeadline {
                Text(FinalizeText.window(deadline: deadline))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
            }
            if queuedFinal != nil {
                queuedButton
            } else {
                renderButton
            }
        }
        .task(id: FinalQuote(spec: finalSpec, kind: kind)) {
            estimatedFinal = nil
            guard kind == .account, let provider else { return }
            estimatedFinal = try? await provider.estimate(finalSpec)
        }
    }

    private var renderButton: some View {
        Button {
            onRender(finalPrice)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                if finalSpec.draftJobID != nil {
                    Label(FinalizeText.title, systemImage: "sparkles")
                } else {
                    Label("Render final", systemImage: "sparkles")
                }
                if let finalPrice {
                    PriceTag(text: LibraryFormat.cost(finalPrice))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.primaryAction)
        .disabled(isWorking || !isConnected)
        .hoverHint(finalSpec.draftJobID != nil ? FinalizeText.help : "")
    }

    private var queuedButton: some View {
        Button {
            navigation.selection = .queue
        } label: {
            Label(QueuedNotice.finalQueuedViewInQueue, systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.secondaryAction)
        .hoverHint("Show in Queue")
    }
}

private struct FinalQuote: Hashable {
    let spec: JobSpec
    let kind: ProviderKind?
}
