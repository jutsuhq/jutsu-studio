import JutsuCore
import Presentation
import SwiftUI

/// Create Character: designs a person or an animal and makes character sheets of it on the account. It is laid out
/// like Generate reference images (`GenerateSheetLayout`): the form on the left, the requests sent from here on the
/// right, and Generate with Higgsfield's quote of the exact request under them. Generate sends that request once
/// (`CharacterBuilder`). Finished sheets are saved to Library › Images and listed in References › From Higgsfield ›
/// Characters, so the sheet can close while they're being made.
struct CreateCharacterSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: CapConfirmation?
    @State private var isStarting = false

    private var builder: CharacterBuilder { environment.characterBuilder }
    private var isBusy: Bool { isStarting || builder.isSubmitting }

    var body: some View {
        GenerateSheetLayout(
            title: String(localized: "Create Character"),
            subtitle: String(
                localized:
                    "A character sheet shows one person or animal from every side. Use it as a reference to keep them the same in every video."
            ),
            formWidth: 400,
            isBusy: isBusy,
            closeHint: isBusy
                ? String(localized: "Wait for Higgsfield to take the request") : String(localized: "Close"),
            onClose: { dismiss() }
        ) {
            CreateCharacterForm()
        } results: {
            requestsPane
        } actions: {
            actions
        }
        .interactiveDismissDisabled(isBusy)
        .task(id: builder.tier) {
            if let maker = environment.characterMaker { await builder.loadTraits(from: maker) }
        }
        .task(id: builder.quoteKey) {
            await refreshQuote()
        }
        .confirmationDialog(
            confirmation?.title ?? "", isPresented: Binding(isPresenting: $confirmation), presenting: confirmation
        ) { confirmation in
            Button(confirmation.confirmTitle) { generate(overCapApproved: true) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    // MARK: Requests

    private var requestsPane: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Requests")
            UnsavedRecordsWarning()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if builder.runs.isEmpty {
                        Text(
                            "Each sheet takes a few minutes. You can close this window: the sheets keep going and show in Characters when they're done."
                        )
                        .font(.callout)
                        .foregroundStyle(Theme.faint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                    ForEach(builder.runs.reversed()) { run in
                        RequestRow(title: String(localized: "\(run.count) character sheets"), status: status(of: run))
                    }
                }
            }
        }
    }

    private func status(of run: CharacterRun) -> RequestRow.Status {
        switch run.state {
        case .sending: .working(String(localized: "Sending…"))
        case .running: .working(String(localized: "Being made"))
        case .finished: .finished(String(localized: "Done · in Characters and Library › Images"))
        case .failed(let message): .failed(message)
        case .interrupted(let message): .failed(message)
        }
    }

    // MARK: Actions

    /// Return generates. The price rides on the button as on Generate reference images; without a quote of the form
    /// as it stands, Generate waits.
    @ViewBuilder private var actions: some View {
        notice
        Spacer(minLength: Theme.Spacing.small)
        Button {
            generate()
        } label: {
            GenerateButtonLabel(isGenerating: isBusy, price: builder.currentQuote?.price)
        }
        .buttonStyle(.primaryAction)
        .keyboardShortcut(.defaultAction)
        .disabled(isBusy || builder.currentQuote == nil || environment.characterMaker == nil)
        .hoverHint(priceHint)
        .accessibilityHint(priceHint)
    }

    /// Where the price comes from, or that it's being asked for.
    private var priceHint: String {
        if let quote = builder.currentQuote { return quote.priceText }
        if builder.isQuoting && environment.characterMaker != nil {
            return String(localized: "Getting the price from Higgsfield…")
        }
        return ""
    }

    /// What the button can't say: why Generate is off, or why there's no price.
    @ViewBuilder private var notice: some View {
        if environment.characterMaker == nil {
            Text("Connect your Higgsfield account to create characters.")
                .font(.callout)
                .foregroundStyle(Theme.muted)
        } else if let blocker = builder.blocker {
            Text(blocker)
                .font(.callout)
                .foregroundStyle(Theme.muted)
        } else if let failure = builder.quoteFailure {
            Text(failure)
                .font(.caption)
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
        }
    }

    /// A quick stop on each change: typing the description doesn't ask for a price on every key.
    private func refreshQuote() async {
        guard let maker = environment.characterMaker, builder.blocker == nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return
        }
        await builder.refreshQuote(maker: maker, upload: environment.characterUploader(maker))
    }

    /// The builder asks first when the price takes today past the cap.
    private func generate(overCapApproved: Bool = false) {
        guard !isBusy, let maker = environment.characterMaker else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            let started = await builder.generate(maker: maker, overCapApproved: overCapApproved)
            if case .needsConfirmation(let question) = started { confirmation = question }
        }
    }
}
