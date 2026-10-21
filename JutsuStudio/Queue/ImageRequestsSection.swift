import Presentation
import SwiftUI

/// Generate… requests, from the Image side of Create or from References: they run beside the job queue
/// (`ReferenceGenerator`), so they are listed on their own, with Cancel while they run. Their images are on the
/// Image side of Create and in Library › Images.
struct ImageRequestsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NavigationModel.self) private var navigation
    /// The agent's held request the person is deciding on.
    @State private var reviewing: ImageRun?

    var body: some View {
        let generator = environment.referenceGenerator
        if !generator.runs.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                SectionLabel(title: "Images", detail: "\(generator.runs.count)")
                Button("Show in Create") {
                    navigation.createKind = .image
                    navigation.selection = .create
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold))
                .hoverHint(String(localized: "Show images in Create"))
            }
            .padding(.top, 18)
            ForEach(generator.runs) { run in
                ImageRunRow(run: run, onCancel: { cancel(run) }, onReview: { reviewing = run })
            }
            .confirmationDialog(
                String(localized: "Send this agent's request?"), isPresented: Binding(isPresenting: $reviewing),
                presenting: reviewing
            ) { run in
                Button("Send") { environment.sendHeldImageRequest(run.id) }
                Button("Cancel Request", role: .destructive) { cancel(run) }
                Button("Not Now", role: .cancel) {}
            } message: { run in
                Text(Self.review(run))
            }
        }
    }

    /// An agent's request goes through its queue, which records how it ended; the person's own straight to Generate….
    private func cancel(_ run: ImageRun) {
        if run.agent != nil {
            environment.agentImages.cancel(run.id)
        } else {
            environment.referenceGenerator.cancel(run.id)
        }
    }

    /// What the person agrees to: who asked, what, at which price, and why it waited.
    private static func review(_ run: ImageRun) -> String {
        let price = run.price.map(ReferenceGenerator.priceText) ?? PostOperationText.unknownPriceNotice
        var reason = ""
        if case .held(let text) = run.state { reason = text }
        return [run.agentTitle ?? "", run.title, price, run.agentDetail ?? "", reason]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
