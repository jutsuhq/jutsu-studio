import Foundation

/// What the active connection can run; drives which modes and options the UI enables.
public struct Capabilities: Sendable, Hashable {
    public enum CostUnit: String, Sendable, Hashable {
        case usd
        case credits
    }

    public var modes: Set<Mode>
    /// Genjutsu always; the others where the connection offers them.
    public var models: Set<VideoModel>
    public var resolutions: Set<Resolution>
    public var costUnit: CostUnit
    /// `nil` when unknown until the API reports it.
    public var maxConcurrency: Int?
    /// The model parameters the connection can send; Create disables the control of any other one and says why.
    public var parameters: Set<ModelParameter>
    /// The modes of each model the account can pay from its plan's unlimited allowance right now, instead of
    /// credits; empty when it has no allowance or the connection can't tell.
    public var unlimited: [VideoModel: Set<Mode>]
    /// The most variants one submit of a generation makes (`JobSpec.variants`); 1 where the connection has none.
    /// A Genjutsu Style and an operation on a result always make one.
    public var maxVariants: Int
    /// Modes of an offered model that this connection can't run though the model serves them: Genjutsu Lite's
    /// Object Swap with an API key, which has no REST endpoint. Empty where every offered model runs all its modes.
    public var unservedModes: [VideoModel: Set<Mode>]

    public init(
        modes: Set<Mode>, models: Set<VideoModel> = [.genjutsu], resolutions: Set<Resolution>, costUnit: CostUnit,
        maxConcurrency: Int?, parameters: Set<ModelParameter> = Set(ModelParameter.allCases),
        unlimited: [VideoModel: Set<Mode>] = [:], maxVariants: Int = 1,
        unservedModes: [VideoModel: Set<Mode>] = [:]
    ) {
        self.modes = modes
        self.models = models
        self.resolutions = resolutions
        self.costUnit = costUnit
        self.maxConcurrency = maxConcurrency
        self.parameters = parameters
        self.unlimited = unlimited
        self.maxVariants = maxVariants
        self.unservedModes = unservedModes
    }

    /// Whether a job on `model` in `mode` runs on this connection: the model is offered, serves the mode, and the
    /// connection runs it in that mode.
    public func runs(_ model: VideoModel, in mode: Mode) -> Bool {
        models.contains(model) && model.serves(mode) && unservedModes[model]?.contains(mode) != true
    }

    /// Whether `spec` is paid from the unlimited allowance: only when the user opted in and the account has it
    /// for the spec's model and mode.
    public func paysUnlimited(_ spec: JobSpec, optedIn: Bool) -> Bool {
        optedIn && unlimited[spec.model]?.contains(spec.mode) == true
    }
}
