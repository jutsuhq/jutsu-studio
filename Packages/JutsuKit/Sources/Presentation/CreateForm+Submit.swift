import Foundation
import JutsuCore

/// What the Create screen knows besides the form: the connection, prices and today's spend.
public struct CreateContext: Sendable, Hashable {
    public var connection: ConnectionState
    /// `nil` while loading or when they couldn't be read; modes are then not restricted.
    public var capabilities: Capabilities?
    /// The bundled list prices, for API key connections.
    public var pricing: Pricing?
    /// Live estimates by `JobSpec.priceKey`. Credits have no price table, so they are known only from here.
    public var estimates: [JobSpec: Cost]
    /// The last known total of Draft (`true`) and Generate (`false`), shown while a changed form is estimated
    /// again (`EstimateCache.lastTotals`). Never used to decide: a submit sees only `cost(for:)`.
    public var lastTotals: [Bool: Cost]
    /// Spend in the cap's unit of jobs finished today plus every job in flight.
    public var committedToday: Decimal
    /// `nil` when there is no daily cap.
    public var cap: SpendCap?
    /// The user opted in to paying from the plan's unlimited allowance (`AppSettings.useUnlimitedKey`).
    public var unlimitedOptIn: Bool

    public init(
        connection: ConnectionState, capabilities: Capabilities? = nil, pricing: Pricing? = nil,
        estimates: [JobSpec: Cost] = [:], lastTotals: [Bool: Cost] = [:], committedToday: Decimal = 0,
        cap: SpendCap? = nil, unlimitedOptIn: Bool = false
    ) {
        self.connection = connection
        self.capabilities = capabilities
        self.pricing = pricing
        self.estimates = estimates
        self.lastTotals = lastTotals
        self.committedToday = committedToday
        self.cap = cap
        self.unlimitedOptIn = unlimitedOptIn
    }

    /// Opted in, and the account has the allowance for the spec's model and mode now. The engine decides again
    /// when the job is queued (`GenerationProvider.paysUnlimited`).
    public func paysUnlimited(_ spec: JobSpec) -> Bool {
        capabilities?.paysUnlimited(spec, optedIn: unlimitedOptIn) == true
    }

    /// Every one of `specs`, and there is at least one.
    public func paysUnlimited(_ specs: [JobSpec]) -> Bool {
        !specs.isEmpty && specs.allSatisfy(paysUnlimited)
    }

    public var costUnit: Capabilities.CostUnit {
        capabilities?.costUnit ?? (connection.kind == .account ? .credits : .usd)
    }

    /// Genjutsu alone until the capabilities are known.
    public var offeredModels: Set<VideoModel> { capabilities?.models ?? [.genjutsu] }

    /// Why Kling can't keep the video's background here; `nil` when it can, or while the capabilities are unknown.
    public var videoBackgroundUnavailableReason: String? {
        unavailableReason(for: .klingVideoBackground)
    }

    /// Plan credits left, when a provider call has reported them.
    public var creditsLeft: Int? {
        guard case .account(let info) = connection else { return nil }
        return info.credits
    }

    /// The live estimate, else the list price for USD; `nil` for credits until estimated. No credits for a job the
    /// unlimited allowance pays, so neither the cap nor the credits left hold it back. An unknown price
    /// (`Cost.isUnknownPrice`) stays one.
    public func cost(for spec: JobSpec) -> Cost? {
        if paysUnlimited(spec) { return .credits(0, isEstimate: false) }
        if let estimate = estimates[spec.priceKey] { return estimate }
        guard costUnit == .usd, let pricing else { return nil }
        return try? pricing.cost(for: spec)
    }

    /// The sum over `specs`; `nil` when any of them isn't estimated yet, or when there are none. When any has an
    /// unknown price, so has the sum: a part of it would read as the whole.
    public func cost(for specs: [JobSpec]) -> Cost? {
        var costs: [Cost] = []
        for spec in specs {
            guard let price = cost(for: spec) else { return nil }
            costs.append(price)
        }
        if let unknown = costs.first(where: \.isUnknownPrice) { return unknown }
        return Cost.total(costs)
    }

    /// Why `mode` can't run on this connection; `nil` while capabilities are unknown.
    public func unavailableReason(for mode: Mode) -> String? {
        guard capabilities != nil else { return nil }
        return ModeOption.all(for: connection, capabilities: capabilities).first { $0.mode == mode }?
            .unavailableReason
    }
}

/// The line above the buttons.
public struct CostLine: Sendable, Hashable {
    /// "13 s × $0.681 = $8.85".
    public var text: String
    /// "List price · failed runs are free".
    public var detail: String
    /// The detail is a warning (over the cap).
    public var isWarning: Bool
}

/// What the submit bar shows, from one build of the Draft and Generate specs rather than one per line and button.
public struct SubmitBarState: Sendable, Hashable {
    public var draftBlocker: String?
    public var generateBlocker: String?
    /// `CreateForm.costLine(in:)`.
    public var costLine: CostLine?
    public var draftPrice: String?
    public var generatePrice: String?

    /// A model without drafts (`CreateForm.offersDraft`) has no Draft button, so no draft blocker or price.
    public init(form: CreateForm, in context: CreateContext) {
        let generate = form.makeSpecs(isDraft: false, in: context)
        let generateCost = context.cost(for: generate)
        generateBlocker = form.blocker(isDraft: false, generateSpecs: generate, cost: generateCost, in: context)
        generatePrice =
            context.paysUnlimited(generate)
            ? CostText.unlimited : (generateCost ?? context.lastTotals[false]).map(CostText.text)
        guard form.offersDraft else {
            costLine = form.costLine(specs: generate, cost: generateCost, in: context)
            return
        }
        let draft = form.makeSpecs(isDraft: true, in: context)
        let draftCost = context.cost(for: draft)
        draftBlocker = form.blocker(isDraft: true, generateSpecs: generate, cost: draftCost, in: context)
        costLine =
            form.isBatch
            ? form.costLine(specs: draft, cost: draftCost, in: context)
            : form.costLine(specs: generate, cost: generateCost, in: context)
        draftPrice =
            context.paysUnlimited(draft)
            ? CostText.unlimited : (draftCost ?? context.lastTotals[true]).map(CostText.text)
    }

    /// The blocker of Draft (`isDraft`) or Generate.
    public func blocker(isDraft: Bool) -> String? {
        isDraft ? draftBlocker : generateBlocker
    }

    /// The price on Draft (`isDraft`) or Generate.
    public func price(isDraft: Bool) -> String? {
        isDraft ? draftPrice : generatePrice
    }
}

/// The over-cap confirmation.
public struct CapConfirmation: Sendable, Hashable {
    public var title: String
    public var message: String
    public var confirmTitle: String
}

public enum SubmitDecision: Sendable, Hashable {
    /// Not submittable; the reason is the blocker text.
    case blocked(String)
    /// Queue these jobs, in order.
    case start([JobSpec])
    /// Over today's cap: ask once, then start all the jobs on confirm.
    case confirm([JobSpec], CapConfirmation)

    /// Start, or ask first when `cost`, the total of `specs`, takes today's spend over `cap`. Shared by
    /// every screen that queues jobs. Under a cap an unknown cost (`nil`, or `Cost.isUnknownPrice`) asks too,
    /// since it could be over; a cost in the other unit than the cap never asks.
    public static func budgeted(
        _ specs: [JobSpec], cost: Cost?, committedToday: Decimal, cap: SpendCap?
    ) -> SubmitDecision {
        guard let cap else { return .start(specs) }
        let capText = CostText.amount(cap.amount, unit: cap.unit)
        let jobs = JobSpec.jobCount(specs)
        guard let cost, !cost.isUnknownPrice else {
            let today = CostText.amount(committedToday, unit: cap.unit)
            return .confirm(
                specs,
                CapConfirmation(
                    title: String(localized: "Price not known yet", bundle: .module),
                    message: jobs == 1
                        ? String(
                            localized: """
                                This job's price isn't known, so it may take today past your \(capText) cap. \
                                Today is at \(today) so far.
                                """, bundle: .module)
                        : String(
                            localized: """
                                These \(jobs) jobs' price isn't known, so it may take today past your \
                                \(capText) cap. Today is at \(today) so far.
                                """, bundle: .module),
                    confirmTitle: String(localized: "Start anyway", bundle: .module)))
        }
        guard
            case .needsConfirmation(let total) = Budget.allows(cost: cost, committedToday: committedToday, cap: cap)
        else { return .start(specs) }
        let amount = CostText.amount(cost.amount, unit: cap.unit)
        let totalText = CostText.amount(total, unit: cap.unit)
        return .confirm(
            specs,
            CapConfirmation(
                title: String(localized: "Over today's spend cap", bundle: .module),
                message: jobs == 1
                    ? String(
                        localized:
                            "This job adds \(amount), bringing today to \(totalText) against your \(capText) cap.",
                        bundle: .module)
                    : String(
                        localized: """
                            These \(jobs) jobs add \(amount), bringing today to \(totalText) \
                            against your \(capText) cap.
                            """, bundle: .module),
                confirmTitle: String(localized: "Start anyway", bundle: .module)))
    }
}

extension CreateForm {
    /// The model the jobs run on: the picked one when it serves the mode, else `Mode.defaultModel`.
    public var selectedModel: VideoModel {
        model.serves(mode) ? model : mode.defaultModel
    }

    /// What one job takes on the selected model, by the server's `constraints` where the app has them: the ranges
    /// and references stay inside these.
    public var limits: ModeLimits {
        selectedModel.limits(
            for: mode, hasSource: source != nil || !selectedModel.makesClipsWithoutSource,
            constraints: constraints ?? .builtIn)
    }

    /// The models the picker offers for the tab, in a fixed order; one entry means no picker. Motion's lists every
    /// model with one of its tasks.
    public func modelOptions(in context: CreateContext) -> [VideoModel] {
        let modes =
            tab == .motionTransfer
            ? Self.motionTasks.filter { $0 == mode || context.unavailableReason(for: $0) == nil } : [mode]
        return VideoModel.allCases.filter { model in
            context.offeredModels.contains(model) && modes.contains(where: model.serves)
        }
    }

    /// Moves a model the connection doesn't offer (Seedance or Kling on an account without `generate_video`) to
    /// Genjutsu, so a re-run or a switch of connection never leaves the form on a model its picker can't show.
    /// `nil` while the capabilities are unknown, which changes nothing.
    public mutating func fitModel(to offered: Set<VideoModel>?) {
        guard let offered, !offered.contains(model) else { return }
        model = .genjutsu
    }

    /// Why Draft (`isDraft`) or Generate can't be submitted, as the cost line shows it; `nil` when it can.
    /// Credits are checked against that action's own cost.
    public func blocker(isDraft: Bool, in context: CreateContext) -> String? {
        blocker(
            isDraft: isDraft, generateSpecs: makeSpecs(isDraft: false, in: context),
            cost: cost(isDraft: isDraft, in: context),
            in: context)
    }

    /// `blocker(isDraft:in:)` over specs and a cost the caller already has; `cost` is the action's own.
    func blocker(
        isDraft: Bool, generateSpecs specs: [JobSpec], cost: @autoclosure () -> Cost?, in context: CreateContext
    ) -> String? {
        guard context.connection.isConnected else {
            return String(localized: "Connect Higgsfield in Settings", bundle: .module)
        }
        if let reason = context.unavailableReason(for: mode) { return reason }
        if let offered = context.capabilities?.models, !offered.contains(selectedModel) {
            return String(localized: "\(selectedModel.title) isn't available on this connection", bundle: .module)
        }
        guard source != nil || isWithoutSource else { return String(localized: "Add a source video", bundle: .module) }
        if usesFrames, let reason = context.unavailableReason(for: .seedanceFrames) { return reason }
        if let reason = framesBlocker { return reason }
        if let reason = batchBlocker { return reason }
        guard !specs.isEmpty else { return String(localized: "Add a source video", bundle: .module) }
        if let reason = validationBlocker(specs) { return reason }
        if let left = context.creditsLeft, case .credits(let needed, _)? = cost(),
            needed > Decimal(left)
        {
            return isDraft || !offersDraft
                ? String(localized: "Not enough credits on your plan", bundle: .module)
                : String(localized: "Not enough credits for Generate, try a draft", bundle: .module)
        }
        return nil
    }

    /// The issue as an action, with the selected model's limits.
    func text(for issue: ValidationIssue) -> String {
        switch issue {
        case .selectionOutsideSource: String(localized: "Pick a range inside the video", bundle: .module)
        case .sourceRequired: String(localized: "Add a source video", bundle: .module)
        case .promptRequired where mode == .edit: String(localized: "Say what should change", bundle: .module)
        case .promptRequired where mode == .extend: String(localized: "Say what happens next", bundle: .module)
        case .promptRequired where selectedModel.descriptor.requiresPrompt:
            String(localized: "Write a prompt", bundle: .module)
        case .promptRequired: String(localized: "Write a prompt or add an image", bundle: .module)
        case .invalidFrameSize: String(localized: "Can't read the video's frame size", bundle: .module)
        case .durationTooShort:
            String(localized: "Pick at least \(CostText.limit(limits.duration.lowerBound)) of video", bundle: .module)
        case .durationTooLong:
            String(localized: "Pick at most \(CostText.limit(limits.duration.upperBound)) of video", bundle: .module)
        case .tooFewReferences(let minimum) where minimum == 1:
            String(localized: "Add at least one image", bundle: .module)
        case .tooFewReferences(let minimum): String(localized: "Add at least \(minimum) images", bundle: .module)
        case .tooManyReferences(let maximum) where selectedModel == .genjutsu:
            maximum == 1
                ? String(localized: "Remove images, this mode takes one", bundle: .module)
                : String(localized: "Remove images, this mode takes up to \(maximum)", bundle: .module)
        case .tooManyReferences(let maximum):
            maximum == 1
                ? String(localized: "Remove images, \(selectedModel.title) takes one", bundle: .module)
                : String(localized: "Remove images, \(selectedModel.title) takes up to \(maximum)", bundle: .module)
        case .presetRequired: String(localized: "Pick a style", bundle: .module)
        case .frameTooSmall: String(localized: "Object swap needs 640×640 px, allow the upscale", bundle: .module)
        case .promptTooLong: String(localized: "Shorten the prompt to 10 000 characters", bundle: .module)
        }
    }

    public func cost(isDraft: Bool, in context: CreateContext) -> Cost? {
        context.cost(for: makeSpecs(isDraft: isDraft, in: context))
    }

    /// The price to show: the estimate of the form as it is, else the last one known while it loads.
    func shownCost(isDraft: Bool, in context: CreateContext) -> Cost? {
        cost(isDraft: isDraft, in: context) ?? context.lastTotals[isDraft]
    }

    /// The price on a button: "$8.85", "96 cr"; the last known one while a changed form is estimated again,
    /// `nil` before any is known.
    public func priceText(isDraft: Bool, in context: CreateContext) -> String? {
        if context.paysUnlimited(makeSpecs(isDraft: isDraft, in: context)) { return CostText.unlimited }
        let cost = shownCost(isDraft: isDraft, in: context)
        // The top of a published range never reads lower than it is.
        if case .usd(let amount, true)? = cost, isUpperBound(at: jobResolution(isDraft: isDraft), in: context) {
            return CostText.dollars(amount, rounding: .up)
        }
        return cost.map(CostText.text)
    }

    /// "$0.681 / s" next to the resolution or quality picker, "up to $0.4623 / s" for the top of a published range;
    /// `nil` for credits, which have no rate table.
    public func rateText(in context: CreateContext) -> String? {
        let resolution = jobResolution(isDraft: false)
        guard context.costUnit == .usd, let rate = rate(at: resolution, in: context) else { return nil }
        guard isUpperBound(at: resolution, in: context) else { return CostText.rate(rate) + " / s" }
        let most = CostText.rate(rate, rounding: .up) + " / s"
        return String(localized: "up to \(most)", bundle: .module)
    }

    /// The list price per second of the form's jobs at `resolution`.
    private func rate(at resolution: Resolution, in context: CreateContext) -> Decimal? {
        try? context.pricing?.rate(
            model: selectedModel, mode: mode, resolution: resolution, hasSource: source != nil,
            hasReferences: !references.isEmpty || usesFrames, usesFrames: usesFrames)
    }

    /// Whether the list price of the form's jobs at `resolution` is only the top of a published range.
    private func isUpperBound(at resolution: Resolution, in context: CreateContext) -> Bool {
        context.pricing?.isUpperBound(
            model: selectedModel, mode: mode, resolution: resolution, hasSource: source != nil,
            hasReferences: !references.isEmpty || usesFrames, usesFrames: usesFrames) == true
    }

    /// "5.0 s · $1.59" next to the draft length picker, over all ranges.
    public func draftLengthDetail(in context: CreateContext) -> String {
        let length = CostText.seconds(draftDuration)
        guard let price = priceText(isDraft: true, in: context) else { return length }
        return "\(length) · \(price)"
    }

    /// The cost of Generate over all ranges, or of the drafts of a batch, which runs as drafts by default
    /// (`runsAsDraft`); `nil` without a source.
    public func costLine(in context: CreateContext) -> CostLine? {
        let specs = makeSpecs(isDraft: runsAsDraft, in: context)
        return costLine(specs: specs, cost: context.cost(for: specs), in: context)
    }

    /// `costLine(in:)` over the specs of that action and their cost (`context.cost(for:)`).
    func costLine(specs: [JobSpec], cost exactCost: Cost?, in context: CreateContext) -> CostLine? {
        let isDraft = runsAsDraft
        guard !specs.isEmpty else { return nil }
        // Each job, and each variant of it, is billed whole seconds on its own.
        let billed = specs.reduce(0) { $0 + Pricing.billedSeconds(for: $1, on: context.connection.kind) * $1.variants }
        let jobs = JobSpec.jobCount(specs)
        let rateResolution = jobResolution(isDraft: isDraft)
        let free = [
            jobs > 1 ? SpendLine.jobsText(jobs) : nil,
            String(localized: "failed runs are free", bundle: .module),
        ]
        if context.paysUnlimited(specs) {
            return CostLine(
                text: "\(billed) s · \(CostText.unlimited)",
                detail: String(
                    localized: "Plan's unlimited generations · not counted in the daily cap", bundle: .module),
                isWarning: false)
        }

        if exactCost?.isUnknownPrice == true { return Self.unknownPriceLine(billed: billed, free: free) }
        let isUpdating = exactCost == nil
        let cost = exactCost ?? context.lastTotals[isDraft]
        let isOverCap = cost.map {
            Budget.allows(cost: $0, committedToday: context.committedToday, cap: context.cap) != .allowed
        }
        let overCap = String(localized: "Over today's cap, you'll be asked to confirm", bundle: .module)
        let estimate = String(localized: "Estimate", bundle: .module)
        switch cost {
        case .usd(let amount, let isEstimate)?:
            let (text, status) = usdLine(
                billed: billed, amount: amount, isEstimate: isEstimate, at: rateResolution, in: context)
            if isOverCap == true { return CostLine(text: text, detail: overCap, isWarning: true) }
            return CostLine(text: text, detail: Self.detail([status] + free), isWarning: false)
        case .credits(let amount, let isEstimate)?:
            let text = String(
                localized: "\(billed) s = \(CostText.exactCredits(amount)) credits", bundle: .module,
                locale: CostText.ungrouped)
            if isOverCap == true { return CostLine(text: text, detail: overCap, isWarning: true) }
            let left = context.creditsLeft.map {
                String(localized: "\(String($0)) cr left on your plan", bundle: .module)
            }
            let status = Self.creditStatus(isUpdating: isUpdating, isEstimate: isEstimate)
            return CostLine(text: text, detail: Self.detail([status, left] + free), isWarning: false)
        case nil:
            return CostLine(
                text: String(localized: "\(billed) s · estimating…", bundle: .module),
                detail: Self.detail([estimate] + free), isWarning: false)
        }
    }

    /// A USD price and where it comes from: "12 s × $0.681 = $8.17" at an exact list price, "15 s = up to $6.94" at
    /// the top of a published range (rounded up), else "12 s = $5.55". A price that is neither an estimate nor an exact
    /// list price is Higgsfield's `/estimate` quote of a job with nothing to upload.
    private func usdLine(
        billed: Int, amount: Decimal, isEstimate: Bool, at resolution: Resolution, in context: CreateContext
    ) -> (text: String, status: String) {
        if isEstimate, isUpperBound(at: resolution, in: context) {
            let most = CostText.dollars(amount, rounding: .up)
            return (
                String(localized: "\(billed) s = up to \(most)", bundle: .module),
                String(localized: "Top of Higgsfield's published range, quoted after upload", bundle: .module)
            )
        }
        let total = CostText.dollars(amount)
        if isEstimate { return ("\(billed) s = \(total)", String(localized: "Estimate", bundle: .module)) }
        guard selectedModel.descriptor.listPriceIsExact else {
            return ("\(billed) s = \(total)", String(localized: "Price from Higgsfield", bundle: .module))
        }
        let text = rate(at: resolution, in: context).map { "\(billed) s × \(CostText.rate($0)) = \(total)" }
        return (text ?? "\(billed) s = \(total)", String(localized: "List price", bundle: .module))
    }

    /// Where a credit price comes from. Not an estimate: Higgsfield's `get_cost` quote. A model billed by its source
    /// is quoted once the source is uploaded, right before the job starts; until then it shows the estimate.
    private static func creditStatus(isUpdating: Bool, isEstimate: Bool) -> String {
        if isUpdating { return String(localized: "Updating the price", bundle: .module) }
        return isEstimate
            ? String(localized: "Estimate, Higgsfield quotes it after upload", bundle: .module)
            : String(localized: "Price from Higgsfield", bundle: .module)
    }

    /// A model no page or quote gives a rate for: the server prices the uploaded files before the job starts.
    private static func unknownPriceLine(billed: Int, free: [String?]) -> CostLine {
        CostLine(
            text: "\(billed) s · \(PostOperationText.priceUnknown)",
            detail: detail(
                [String(localized: "Higgsfield quotes it once the files are uploaded", bundle: .module)] + free),
            isWarning: false)
    }

    /// The cost line's detail: phrases translated one by one and joined by " · ".
    private static func detail(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// What pressing Draft (`isDraft`) or Generate does.
    public func submitDecision(isDraft: Bool, in context: CreateContext) -> SubmitDecision {
        if let reason = blocker(isDraft: isDraft, in: context) { return .blocked(reason) }
        let specs = makeSpecs(isDraft: isDraft, in: context)
        guard !specs.isEmpty else { return .blocked(String(localized: "Add a source video", bundle: .module)) }
        return .budgeted(
            specs, cost: context.cost(for: specs), committedToday: context.committedToday, cap: context.cap)
    }
}
