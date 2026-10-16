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

    public init(
        modes: Set<Mode>, models: Set<VideoModel> = [.genjutsu], resolutions: Set<Resolution>, costUnit: CostUnit,
        maxConcurrency: Int?, parameters: Set<ModelParameter> = Set(ModelParameter.allCases),
        unlimited: [VideoModel: Set<Mode>] = [:], maxVariants: Int = 1
    ) {
        self.modes = modes
        self.models = models
        self.resolutions = resolutions
        self.costUnit = costUnit
        self.maxConcurrency = maxConcurrency
        self.parameters = parameters
        self.unlimited = unlimited
        self.maxVariants = maxVariants
    }

    /// Whether `spec` is paid from the unlimited allowance: only when the user opted in and the account has it
    /// for the spec's model and mode.
    public func paysUnlimited(_ spec: JobSpec, optedIn: Bool) -> Bool {
        optedIn && unlimited[spec.model]?.contains(spec.mode) == true
    }
}
