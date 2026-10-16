import JutsuCore
import Presentation
import SwiftUI

/// Score Variants… in the comparison's toolbar: asks the account's Virality Predictor about the results not scored
/// yet, or, once every one is, all of them again. Hidden or off with the reason as `ViralityAvailability` says.
struct ScoreVariantsButton: View {
    let batch: LibraryBatch

    @Environment(AppEnvironment.self) private var environment
    @State private var request: ScoreRequest?

    var body: some View {
        let availability = environment.viralityAvailability
        if availability != .hidden {
            let current = ViralityPlan(batch.items, owner: environment.provider?.owner)
            let reason: String? =
                if case .disabled(let reason) = availability { reason } else { current.blocker }
            Button(current.buttonTitle, systemImage: "chart.line.uptrend.xyaxis") {
                request = ScoreRequest(plan: current)
            }
            .buttonStyle(.secondaryAction)
            .disabled(reason != nil || environment.variantScorer.isRunning)
            .hoverHint(reason ?? String(localized: "Predict virality"))
            .sheet(item: $request) { ScoreVariantsSheet(plan: $0.plan) }
        }
    }
}

private struct ScoreRequest: Identifiable {
    let id = UUID()
    let plan: ViralityPlan
}

/// The price of a scoring run and the agreement to it. Nothing is sent without a price on screen: "Free" for the
/// account's Virality Predictor, the quote for every video, or, where there is none, "Price unknown" and the user's
/// explicit agreement to it.
private struct ScoreVariantsSheet: View {
    let plan: ViralityPlan

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The price of one video; `nil` while it is asked for.
    @State private var each: Cost?
    @State private var acceptsUnknownPrice = false
    @State private var overCap: CapConfirmation?

    private var total: Cost? { each.map { plan.total(each: $0) } }

    private var canScore: Bool {
        guard let total, environment.viralityScorer != nil else { return false }
        return total != .unknownCredits || acceptsUnknownPrice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Text(plan.isRescore ? String(localized: "Score Again") : String(localized: "Score Variants"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if plan.isRescore { Text(ViralityPlan.rescoreNotice).foregroundStyle(Theme.warning) }
                if let total {
                    Text(plan.priceText(total))
                    if total == .unknownCredits {
                        Toggle(PostOperationText.unknownPriceConsent, isOn: $acceptsUnknownPrice)
                            .toggleStyle(.checkbox)
                    }
                } else {
                    Text("Asking Higgsfield for the price…")
                }
                Text("Scores are kept on each result. Picking the winner stays up to you.")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            HStack(spacing: Theme.Spacing.small) {
                Spacer(minLength: Theme.Spacing.small)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await score() }
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Label(
                            plan.isRescore ? String(localized: "Score Again") : String(localized: "Score"),
                            systemImage: "chart.line.uptrend.xyaxis")
                        if let total, total != .unknownCredits { PriceTag(text: ViralityPlan.priceTag(total)) }
                    }
                }
                .buttonStyle(.primaryAction)
                .keyboardShortcut(.defaultAction)
                .disabled(!canScore)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.background)
        .task { each = await environment.viralityEstimate(plan) }
        .confirmationDialog(
            overCap?.title ?? "", isPresented: Binding(isPresenting: $overCap), titleVisibility: .visible,
            presenting: overCap
        ) { confirmation in
            Button(confirmation.confirmTitle) { Task { await score(overCapApproved: true) } }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// Runs on after the sheet closes; each score is saved on its result as it arrives. Under a cap, a price over it
    /// or not known asks first, as Create does.
    private func score(overCapApproved: Bool = false) async {
        guard let scorer = environment.viralityScorer, let each else { return }
        let environment = environment
        let started = await environment.variantScorer.score(
            plan, provider: scorer, each: each, overCapApproved: overCapApproved
        ) { id, score in
            environment.saveVirality(score, for: id)
        }
        if case .needsConfirmation(let question) = started {
            overCap = question
        } else {
            dismiss()
        }
    }
}

/// A cell's score: a 0–100 badge that opens every reading, a small line of the per-second readings, "Open report"
/// when only a report came back, the reason a result can't be scored, or why its last scoring gave nothing.
struct ViralityBadge: View {
    let item: LibraryItemModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var showsDetails = false

    var body: some View {
        if environment.viralityAvailability != .hidden {
            HStack(spacing: Theme.Spacing.xSmall) {
                if environment.variantScorer.scoring.contains(item.id) {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("Scoring"))
                } else if let score = item.job.virality {
                    if let badge = score.badgeText {
                        Button {
                            showsDetails = true
                        } label: {
                            HStack(spacing: Theme.Spacing.xSmall) {
                                Text(badge)
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent, in: Capsule())
                                let curve = score.curve
                                if !curve.isEmpty {
                                    ViralityCurve(points: curve)
                                        .stroke(Theme.accent, lineWidth: 1.2)
                                        .frame(width: 44, height: 14)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHint(score.help)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(score.accessibilityLabel))
                        .accessibilityAddTraits(.isButton)
                        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { ViralityDetails(score: score) }
                    } else if let report = score.reportURL {
                        Button("Open report") { openURL(report) }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                            .hoverHint(score.help)
                    }
                } else if let failure = environment.variantScorer.failures[item.id] {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                        .hoverHint(failure)
                        .accessibilityLabel(Text(failure))
                } else if let blocker = item.viralityBlocker(owner: environment.provider?.owner) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(Theme.faint)
                        .hoverHint(blocker)
                        .accessibilityLabel(Text(blocker))
                }
            }
        }
    }
}

/// Every reading of a score: the overall score, viral potential, hook, engagement, sustain and peak, the line of
/// per-second readings, the disclaimer, and the dashboard on Higgsfield.
private struct ViralityDetails: View {
    let score: ViralityScore

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(score.headline)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(score.details, id: \.self) { Text($0) }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
            let curve = score.curve
            if !curve.isEmpty {
                ViralityCurve(points: curve)
                    .stroke(Theme.accent, lineWidth: 1.5)
                    .frame(height: 36)
                    .accessibilityHidden(true)
            }
            if let disclaimer = score.disclaimer {
                Text(disclaimer)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = score.reportURL {
                Button("Open dashboard") { openURL(report) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .hoverHint(String(localized: "Open report on Higgsfield"))
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 260, alignment: .leading)
    }
}

/// A line through `points`, each 0–1 from the bottom of the frame to its top, spread evenly across it.
private struct ViralityCurve: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let step = rect.width / CGFloat(points.count - 1)
        for (index, value) in points.enumerated() {
            let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(value) * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
