import Foundation
import JutsuCore
import Observation

/// Whether batch comparison shows Score Variants, and whether it can run.
public enum ViralityAvailability: Sendable, Hashable {
    case hidden
    /// Shown, off for `reason`.
    case disabled(reason: String)
    case available

    /// - Parameters:
    ///   - scorer: the active connection's virality scoring; `nil` while disconnected or where it has none.
    ///   - offered: whether the account's scoring call is confirmed (`HiggsfieldMCPProvider.offersVirality`).
    public static func of(scorer: (any ViralityScoring)?, offered: Bool) -> ViralityAvailability {
        guard scorer != nil else { return .hidden }
        return offered ? .available : .disabled(reason: PostOperationText.waitingForCatalog)
    }
}

extension LibraryItemModel {
    /// The account job ID the result is scored by; `nil` when it can't be (`viralityBlocker`).
    /// - Parameter owner: `GenerationProvider.owner` of the signed-in account.
    public func viralityJobID(owner: String?) -> String? {
        viralityBlocker(owner: owner) == nil ? job.remote?.requestID : nil
    }

    /// Why the result can't be scored by the signed-in account; `nil` when it can.
    public func viralityBlocker(owner: String?) -> String? {
        guard job.state == .done, outputFile != nil else {
            return String(localized: "Can't be scored: not finished", bundle: .module)
        }
        guard job.providerKind == .account else {
            return String(localized: "Can't be scored: made with an API key", bundle: .module)
        }
        guard job.owner == owner else {
            return String(localized: "Can't be scored: made by another account", bundle: .module)
        }
        guard job.remote?.requestID.isEmpty == false else {
            return String(localized: "Can't be scored: no account job ID", bundle: .module)
        }
        return nil
    }
}

/// Which results of a batch Score Variants scores: the ones not scored yet, or, once every one is, all of them
/// again, which the sheet says is paid again.
public struct ViralityPlan: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var itemID: UUID
        public var jobID: String
    }

    public var entries: [Entry]
    /// Every scorable result already has a score: scoring them again is paid again.
    public var isRescore: Bool

    public init(_ items: [LibraryItemModel], owner: String?) {
        let scorable = items.compactMap { item in
            item.viralityJobID(owner: owner).map { (item, Entry(itemID: item.id, jobID: $0)) }
        }
        let unscored = scorable.filter { $0.0.job.virality == nil }.map(\.1)
        isRescore = unscored.isEmpty && !scorable.isEmpty
        entries = isRescore ? scorable.map(\.1) : unscored
    }

    public var count: Int { entries.count }

    /// The toolbar button.
    public var buttonTitle: String {
        isRescore
            ? String(localized: "Score Again…", bundle: .module)
            : String(localized: "Score Variants…", bundle: .module)
    }

    /// Why there is nothing to score; `nil` when there is.
    public var blocker: String? {
        entries.isEmpty ? String(localized: "None of these results can be scored", bundle: .module) : nil
    }

    /// The price of the whole plan from the price of one result: `Cost.unknownCredits` when that isn't known.
    public func total(each: Cost?) -> Cost {
        switch each {
        case .credits(let amount, let isEstimate)? where each != .unknownCredits:
            .credits(amount * Decimal(count), isEstimate: isEstimate)
        case .usd(let amount, let isEstimate)?:
            .usd(amount * Decimal(count), isEstimate: isEstimate)
        default:
            .unknownCredits
        }
    }

    /// A price of nothing, as the account's Virality Predictor has.
    public static func isFree(_ total: Cost) -> Bool {
        total.amount == 0 && !total.isUnknownPrice
    }

    /// The price on the Score button: "12 cr", or "Free".
    public static func priceTag(_ total: Cost) -> String {
        isFree(total) ? String(localized: "Free", bundle: .module) : LibraryFormat.cost(total)
    }

    /// "3 videos · 12 cr · Price from Higgsfield", "3 videos · Free", or the unknown price.
    public func priceText(_ total: Cost) -> String {
        let videos = String(localized: "\(count) videos", bundle: .module)
        if total == .unknownCredits { return "\(videos) · \(PostOperationText.unknownPriceNotice)" }
        if Self.isFree(total) { return String(localized: "\(videos) · Free", bundle: .module) }
        let amount = LibraryFormat.cost(total)
        return total.isEstimate
            ? String(localized: "\(videos) · About \(amount) · Estimate", bundle: .module)
            : String(localized: "\(videos) · \(amount) · Price from Higgsfield", bundle: .module)
    }

    /// What the sheet says before a re-score.
    public static let rescoreNotice = String(
        localized: "Every variant already has a score. Scoring them again replaces those scores.", bundle: .module)

    /// The question to ask before scoring when the price takes today past the cap, or isn't known under one;
    /// `nil` to go ahead, always for a free run.
    public static func capConfirmation(total: Cost, committedToday: Decimal, cap: SpendCap?) -> CapConfirmation? {
        guard let cap, !isFree(total) else { return nil }
        let capText = CostText.amount(cap.amount, unit: cap.unit)
        guard total != .unknownCredits else {
            return CapConfirmation(
                title: String(localized: "Price not known yet", bundle: .module),
                message: String(
                    localized: """
                        These scores' price isn't known, so they may take today past your \(capText) cap. Today is \
                        at \(CostText.amount(committedToday, unit: cap.unit)) so far.
                        """, bundle: .module),
                confirmTitle: String(localized: "Score anyway", bundle: .module))
        }
        guard case .needsConfirmation(let total) = Budget.allows(cost: total, committedToday: committedToday, cap: cap)
        else { return nil }
        return CapConfirmation(
            title: String(localized: "Over today's spend cap", bundle: .module),
            message: String(
                localized: """
                    These scores bring today to \(CostText.amount(total, unit: cap.unit)) against your \(capText) cap.
                    """, bundle: .module),
            confirmTitle: String(localized: "Score anyway", bundle: .module))
    }
}

extension ViralityScore {
    /// The badge, "72"; `nil` when only a report came back.
    public var badgeText: String? { score.map(String.init) }

    /// The readings the answer named, one per line: "Viral potential: 45", "Hook (0–3 s): 29", "Peak at 12 s".
    public var details: [String] {
        [
            viralPotential.map { String(localized: "Viral potential: \($0)", bundle: .module) },
            hook.map { String(localized: "Hook (0–3 s): \($0)", bundle: .module) },
            engagement.map { String(localized: "Engagement: \($0)", bundle: .module) },
            sustain.map { String(localized: "Sustain: \($0)", bundle: .module) },
            peakSecond.map { String(localized: "Peak at \(Self.seconds($0))", bundle: .module) },
        ].compactMap(\.self)
    }

    /// "Virality score 72 of 100", or the report alone.
    public var headline: String {
        score.map { String(localized: "Virality score \($0) of 100", bundle: .module) }
            ?? String(localized: "Virality report on Higgsfield", bundle: .module)
    }

    /// The badge's hover text: the score out of 100, the readings, then the disclaimer.
    public var help: String {
        ([headline] + details + [disclaimer].compactMap(\.self)).joined(separator: "\n")
    }

    /// What VoiceOver reads for the badge: everything the hover shows.
    public var accessibilityLabel: String {
        help.replacingOccurrences(of: "\n", with: ", ")
    }

    /// The per-frame readings scaled to 0–1 between their lowest and highest, for a small line; empty with fewer
    /// than two, or when they never change.
    public var curve: [Double] {
        guard let values = perFrame, values.count > 1, let low = values.min(), let high = values.max(), high > low
        else { return [] }
        return values.map { ($0 - low) / (high - low) }
    }

    /// "12 s", "2.5 s".
    static func seconds(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...1)).locale(CostText.locale))
        return String(localized: "\(number) s", bundle: .module)
    }
}

/// Runs Score Variants: one paid call per result, one after the other, so a refusal stops nothing else and every
/// call's price is counted. Lives as long as the app, so leaving the comparison doesn't lose a run. Each call's price
/// goes into the `ImageSpendLog` from the moment it is sent, so the daily cap and Spending count it; a call refused
/// before it ran is taken off again, one that may have been charged stays, even when its answer can't be read.
@MainActor
@Observable
public final class VariantScorer {
    public static let modelTitle = "Virality Predictor"
    static let unreadable = String(
        localized: "Higgsfield's answer couldn't be read, so no score was kept. It may have been charged.",
        bundle: .module)

    /// Results whose call is running or waiting its turn.
    public private(set) var scoring: Set<UUID> = []
    /// Why the last call for a result gave no score.
    public private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let spend: ImageSpendLog
    @ObservationIgnored private let spendStatus: SpendStatusReader
    @ObservationIgnored private let now: @Sendable () -> Date

    /// - Parameter spendStatus: today's spend and the cap, read before each run is started.
    public init(
        spend: ImageSpendLog, spendStatus: @escaping SpendStatusReader = { _ in nil },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.spend = spend
        self.spendStatus = spendStatus
        self.now = now
    }

    public var isRunning: Bool { !scoring.isEmpty }

    /// Starts scoring `plan`'s results in a task of its own, which outlives the sheet, and hands each score to
    /// `save`; returns once the run has started. Unless `overCapApproved`, today's spend is read first, and a price
    /// that takes today past the cap, or isn't known under one, scores nothing and asks
    /// (`ViralityPlan.capConfirmation`; never for a free run).
    /// - Parameters:
    ///   - each: the price of one result the user agreed to; `Cost.unknownCredits` counts as nothing until an
    ///     answer names what it charged.
    ///   - overCapApproved: the user agreed to go past today's cap with this run.
    ///   - save: stores the score on the result; called on the main actor as each one arrives.
    @discardableResult
    public func score(
        _ plan: ViralityPlan, provider: any ViralityScoring, each: Cost, overCapApproved: Bool = false,
        save: @escaping @MainActor (UUID, ViralityScore) -> Void
    ) async -> PaidStart {
        do {
            if (each.amount > 0 || each.isUnknownPrice), let status = try await spendStatus(.account), !overCapApproved,
                let question = ViralityPlan.capConfirmation(
                    total: plan.total(each: each), committedToday: status.committedToday, cap: status.cap)
            {
                return .needsConfirmation(question)
            }
        } catch {
            for entry in plan.entries { failures[entry.itemID] = error.localizedDescription }
            return .notStarted
        }
        let entries = plan.entries.filter { !scoring.contains($0.itemID) }
        guard !entries.isEmpty else { return .notStarted }
        scoring.formUnion(entries.map(\.itemID))
        Task { [weak self] in
            await self?.run(entries, provider: provider, each: each, save: save)
        }
        return .started
    }

    private func run(
        _ entries: [ViralityPlan.Entry], provider: any ViralityScoring, each: Cost,
        save: @escaping @MainActor (UUID, ViralityScore) -> Void
    ) async {
        defer { scoring.subtract(entries.map(\.itemID)) }
        for entry in entries {
            guard !Task.isCancelled else { return }
            failures[entry.itemID] = nil
            await score(entry, provider: provider, each: each, save: save)
            scoring.remove(entry.itemID)
        }
    }

    private func score(
        _ entry: ViralityPlan.Entry, provider: any ViralityScoring, each: Cost,
        save: @MainActor (UUID, ViralityScore) -> Void
    ) async {
        let charge = UUID()
        do {
            try spend.add(
                ImageCharge(
                    id: charge, date: now(), cost: each, providerKind: .account, model: Self.modelTitle, images: 1,
                    purpose: .viralityScore))
        } catch {
            failures[entry.itemID] = ImageSpendLog.notSent(error)
            return
        }
        do {
            let outcome = try await provider.scoreVirality(jobID: entry.jobID)
            spend.settle(charge, at: outcome.charged)
            if let score = outcome.score {
                save(entry.itemID, score)
            } else {
                failures[entry.itemID] = Self.unreadable
            }
        } catch {
            if ReferenceGenerator.wasRefused(error) || error is CancellationError {
                spend.remove(charge)
            } else {
                spend.settle(charge)
            }
            failures[entry.itemID] = UserMessage(error)?.message ?? Self.unreadable
        }
    }
}
