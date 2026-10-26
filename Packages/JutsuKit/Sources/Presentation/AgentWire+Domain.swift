import Foundation
import JutsuAgent
import JutsuCore

// The agents' wire types (JutsuAgent) from the app's own values and back, in one place: JutsuAgent knows nothing of
// the app, so the helper links none of it, and these are the only translations between the two.

extension AgentBudgetUnit {
    public init(_ unit: AgentMoney.Unit) {
        self = unit == .usdCents ? .usdCents : .credits
    }

    /// What `kind`'s agent budget counts in: cents with an API key, credits on an account.
    public init(for kind: ProviderKind) {
        self.init(AgentMoney.unit(for: kind))
    }
}

extension AgentMoney.Unit {
    public init(_ unit: AgentBudgetUnit) {
        self = unit == .usdCents ? .usdCents : .credits
    }
}

extension AgentAmount {
    public init(_ money: AgentMoney) {
        self.init(money.amount, AgentBudgetUnit(money.unit))
    }
}

extension AgentMoney {
    public init(_ amount: AgentAmount) {
        self.init(amount.amount, Unit(amount.unit))
    }
}

extension LibraryKind {
    /// Everything when left out.
    public init(_ kind: AgentLibraryKind?) {
        self =
            switch kind {
            case .video?: .video
            case .image?: .image
            case .all?, nil: .all
            }
    }
}

extension PostAction.Kind {
    public init(_ operation: AgentEnhancement) {
        self =
            switch operation {
            case .upscale: .upscale
            case .reframe: .reframe
            case .removeBackground: .removeBackground
            case .dub: .dub
            case .changeVoice: .changeVoice
            }
    }
}

extension Culling {
    public init(_ verdict: AgentVerdict) {
        self =
            switch verdict {
            case .unreviewed: .unreviewed
            case .kept: .kept
            case .rejected: .rejected
            }
    }
}

extension AgentVerdict {
    public init(_ culling: Culling) {
        self =
            switch culling {
            case .unreviewed: .unreviewed
            case .kept: .kept
            case .rejected: .rejected
            }
    }
}

extension CullingAction {
    public init(_ culling: AgentCulling) {
        self =
            switch culling {
            case .keep: .keep
            case .reject: .reject
            case .clear: .clear
            }
    }
}

extension ExportPreset {
    public init(_ preset: AgentExportPreset) {
        self =
            switch preset {
            case .premiere: .premiere
            case .davinciResolve: .davinciResolve
            case .finalCutPro: .finalCutPro
            case .editingH264: .editingH264
            }
    }
}

extension AgentExportFile.Status {
    public init(_ status: DeliveryResult.Status) {
        self =
            switch status {
            case .done: .done
            case .failed: .failed
            case .skipped: .skipped
            }
    }
}

extension AgentCapabilities.ImageModel {
    /// An image model of the connection as `create_image` takes it, its inputs within the protocol's bound.
    public init(_ model: JutsuCore.ImageModel) {
        let input =
            switch model.input {
            case .none: "none"
            case .optional: "optional"
            case .required: "required"
            }
        self.init(
            id: model.id, title: model.title, counts: model.variantCounts, aspectRatios: model.aspectRatios,
            input: input, maxInputs: min(model.inputLimit, AgentImageRequest.maxInputs),
            maxInputsNote: model.inputLimitIsBound ? Self.boundNote : nil)
    }
}

extension AgentLibraryItem {
    /// A Library row as `library_search` and `library_get` list it.
    public init(_ hit: AgentLibraryHit) {
        self.init(
            id: hit.id, kind: hit.isVideo ? .video : .image, file: hit.file?.path(percentEncoded: false),
            model: hit.model, mode: hit.mode, aspectRatio: hit.aspectRatio, duration: hit.duration,
            price: hit.price.flatMap(AgentMoney.init).map(AgentAmount.init), verdict: AgentVerdict(hit.culling),
            starred: hit.isStarred, createdAt: hit.createdAt, prompt: hit.prompt,
            promptTruncated: hit.isPromptTruncated, versionID: hit.versionID, version: hit.version,
            versionCount: hit.versionCount, jobID: hit.jobID, onHiggsfield: hit.isOnHiggsfield ? true : nil)
    }
}

extension AgentLibraryInput {
    public init(_ input: AgentLibraryDetail.Input) {
        self.init(
            role: input.role, position: input.position, file: input.file?.path(percentEncoded: false),
            item: input.item, onHiggsfield: input.isOnHiggsfield, start: input.range?.lowerBound,
            end: input.range?.upperBound)
    }
}

extension AgentLibrarySettings {
    public init(_ settings: AgentLibraryDetail.Settings) {
        self.init(
            resolution: settings.resolution, draft: settings.isDraft, audio: settings.audio, style: settings.style,
            length: settings.length, aspectRatio: settings.aspectRatio, paidWithUnlimited: settings.paidWithUnlimited,
            operation: settings.operation, count: settings.count)
    }
}

extension AgentLibraryDetails {
    /// One item in full as `library_get` answers it, with a pointer to `library_download` for one only on Higgsfield.
    public init(_ detail: AgentLibraryDetail) {
        self.init(
            item: AgentLibraryItem(detail.hit), inputs: detail.inputs.map(AgentLibraryInput.init),
            settings: AgentLibrarySettings(detail.settings),
            next: detail.hit.isOnHiggsfield ? Self.downloadNext : nil)
    }
}
