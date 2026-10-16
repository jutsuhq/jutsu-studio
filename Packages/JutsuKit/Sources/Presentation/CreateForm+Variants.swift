import Foundation
import JutsuCore

// MARK: Variants

extension CreateForm {
    /// The Variants stepper's range (`JobSpec.variants`).
    public static let variantChoices = 1...JobSpec.maximumVariants

    /// How many variants of each job one submit makes, as picked; the jobs take `variants(in:)`.
    public var variants: Int {
        get { picks.variants ?? 1 }
        set { picks.variants = min(max(newValue, Self.variantChoices.lowerBound), Self.variantChoices.upperBound) }
    }

    /// The stepper is shown where a submit can make more than one video (`Capabilities.maxVariants`); not while
    /// the capabilities are unknown.
    public func showsVariants(in context: CreateContext) -> Bool {
        (context.capabilities?.maxVariants ?? 1) > 1
    }

    /// Why the jobs make one variant whatever is picked; `nil` when they make `variants`.
    public func variantsUnavailableReason(in context: CreateContext) -> String? {
        guard let capabilities = context.capabilities else { return nil }
        guard capabilities.maxVariants > 1 else {
            return String(localized: "This connection makes one video per job", bundle: .module)
        }
        if mode == .restyle { return String(localized: "A style makes one video per run", bundle: .module) }
        if isBatch && offersBatch {
            return String(localized: "A batch makes one video per style or character", bundle: .module)
        }
        if context.paysUnlimited(makeSpecs(isDraft: false)) {
            return String(localized: "Unlimited generations make one video at a time", bundle: .module)
        }
        return nil
    }

    /// The variants each job makes on this connection: what is picked, else 1 while the connection's capabilities
    /// are unknown or `variantsUnavailableReason` says why not.
    public func variants(in context: CreateContext) -> Int {
        guard let maximum = context.capabilities?.maxVariants, variantsUnavailableReason(in: context) == nil else {
            return 1
        }
        return min(variants, maximum)
    }

    /// The jobs Draft (`isDraft`) or Generate queues on this connection, each making `variants(in:)` variants.
    public func makeSpecs(isDraft: Bool, in context: CreateContext) -> [JobSpec] {
        let count = variants(in: context)
        return makeSpecs(isDraft: isDraft).map { spec in
            var spec = spec
            spec.variants = count
            return spec
        }
    }
}
