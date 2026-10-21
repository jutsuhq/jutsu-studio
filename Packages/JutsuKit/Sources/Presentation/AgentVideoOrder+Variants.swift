import Foundation
import JutsuCore

/// How many videos one job of a model and mode makes on this connection, and why only one: what `capabilities` and
/// `quote` say before `create_video` refuses `variants`. The same rules as Create's variants stepper
/// (`CreateForm.variantsUnavailableReason`), in English for agents.
extension AgentVideoOrder {
    public struct Variants: Sendable, Hashable {
        /// The most `variants` takes.
        public var maximum: Int
        /// Why it is one; `nil` when more are offered.
        public var reason: String?

        public init(maximum: Int, reason: String? = nil) {
            self.maximum = maximum
            self.reason = reason
        }
    }

    /// - Parameters:
    ///   - capabilities: the connection's, as last read; `nil` while not known.
    ///   - unlimitedOptIn: the person's Use unlimited generations.
    public static func variants(
        of model: VideoModel, in mode: Mode, capabilities: Capabilities?, unlimitedOptIn: Bool
    ) -> Variants {
        guard let capabilities else {
            return Variants(
                maximum: 1, reason: "The connection's limits aren't read yet; quote a video first, then ask again.")
        }
        guard capabilities.maxVariants > 1 else {
            return Variants(maximum: 1, reason: "This connection makes one video per job.")
        }
        if mode == .restyle { return Variants(maximum: 1, reason: "A style makes one video per run.") }
        if unlimitedOptIn, capabilities.unlimited[model]?.contains(mode) == true {
            // The engine pays from the allowance whenever the person opted in and it covers the job; nothing sends
            // one job with credits instead.
            return Variants(
                maximum: 1,
                reason: "The plan's unlimited generations pay for this model and mode, and they make one video per "
                    + "job. Variants paid with credits need the person to turn off Use unlimited generations in "
                    + "Settings; agents can't choose credits for one job.")
        }
        return Variants(maximum: capabilities.maxVariants)
    }
}
