import JutsuCore
import Presentation
import SwiftUI

/// The line over a batch's jobs: what it compares, how far it is and what it costs so far, and Cancel all.
struct BatchHeader: View {
    let batch: JobBatch

    @Environment(AppEnvironment.self) private var environment
    @Environment(ConnectionStore.self) private var connection
    @State private var isCanceling = false
    /// Asked before Cancel all once a job is with Higgsfield.
    @State private var confirmation: BatchCancel.Confirmation?

    var body: some View {
        let cancel = BatchCancel(batch)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(Theme.accent)
                    Text(batch.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.small)
                    Text([batch.progressText, batch.totalCostText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
                .accessibilityElement(children: .combine)
                if !cancel.isEmpty {
                    Button("Cancel All") {
                        if let ask = cancel.confirmation { confirmation = ask } else { cancelAll(cancel.jobs) }
                    }
                    .buttonStyle(.secondaryAction)
                    .disabled(isCanceling)
                    .hoverHint(String(localized: "Cancel unstarted jobs"))
                }
            }
            if batch.isActive {
                RenderProgress(value: batch.progress)
            }
        }
        .padding(Theme.Spacing.medium)
        .card()
        .confirmationDialog(
            confirmation?.title ?? "", isPresented: Binding(isPresenting: $confirmation), titleVisibility: .visible,
            presenting: confirmation
        ) { confirmation in
            // The jobs as they are now: one may have started or finished while the dialog was up.
            Button(confirmation.confirmTitle, role: .destructive) { cancelAll(BatchCancel(batch).jobs) }
            Button("Keep Them", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// Cancels each job through the engine, as its row's Cancel does, then says which ones it refused.
    private func cancelAll(_ jobs: [Job]) {
        let environment = environment
        isCanceling = true
        Task {
            defer { isCanceling = false }
            var refusals: [UserMessage] = []
            for job in jobs {
                if let refusal = await environment.perform(.cancel, on: job.id, kind: job.providerKind) {
                    refusals.append(refusal)
                }
            }
            if let message = BatchCancel.outcome(refusals: refusals, of: jobs.count) { connection.alert = message }
        }
    }
}
