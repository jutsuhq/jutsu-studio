import Foundation
import JutsuCore

/// The texts of the Enhance menu's operations on a result's page.
public enum PostOperationText {
    public static let priceUnknown = String(localized: "Price unknown", bundle: .module)
    public static let chargedOnCompletion = String(localized: "Charged on completion", bundle: .module)
    /// Only Reframe has a cost preflight, and no public page states the others' rates, so the user agrees to an open
    /// price.
    public static let unknownPriceNotice = String(
        localized: "Price unknown — charged on completion. Higgsfield gives no quote for this before it runs.",
        bundle: .module)
    /// An operation Higgsfield prices only once it has run (`PostAction.isPricedAfterRun`, Topaz).
    public static let priceAfterRun = String(localized: "Price shown after the run", bundle: .module)
    public static let priceAfterRunNotice = String(
        localized:
            "Price shown after the run. Higgsfield gives no quote for a Topaz upscale; Jutsu reads what it charged from your credit history when it finishes.",
        bundle: .module)
    public static let unknownPriceConsent = String(
        localized: "Charge whatever Higgsfield bills when it finishes", bundle: .module)
    public static let waitingForCatalog = String(
        localized: "Waiting for the account's tool catalog to be confirmed", bundle: .module)
    public static let needsAccount = String(localized: "Needs a Higgsfield account", bundle: .module)
    public static let menuTitle = String(localized: "Enhance", bundle: .module)
    /// What Remove Background makes, as seen live on 2026-10-15: the subject on black in an MP4 without alpha, which
    /// came without sound (the source's is put back, `PostAction.restoresSourceSound`).
    public static let removeBackgroundNote = String(
        localized:
            "The subject stays on a black background, in an MP4 without transparency. The clip's sound is put back.",
        bundle: .module)

    /// "About 12 credits · Estimate", "12 credits · Price from Higgsfield", or the unknown price: shown after the
    /// run for `action` when Higgsfield prices it only then.
    public static func price(_ cost: Cost, for action: PostAction? = nil) -> String {
        if cost == .unknownCredits {
            return action?.isPricedAfterRun == true ? priceAfterRunNotice : unknownPriceNotice
        }
        let amount = LibraryFormat.cost(cost)
        return cost.isEstimate
            ? String(localized: "About \(amount) · Estimate · charged on completion", bundle: .module)
            : String(localized: "\(amount) · Price from Higgsfield · charged on completion", bundle: .module)
    }
}

extension PostAction {
    /// "Upscale to 4K", "Reframe to 9:16", "Remove Background", "Dub into French", "Change Voice to Amber".
    public var title: String {
        switch self {
        case .upscale(let options):
            String(localized: "Upscale to \(options.target.title)", bundle: .module)
        case .removeBackground:
            String(localized: "Remove Background", bundle: .module)
        case .reframe(let aspect):
            String(localized: "Reframe to \(aspect.rawValue)", bundle: .module)
        case .dub(let language):
            String(localized: "Dub into \(language.title())", bundle: .module)
        case .changeVoice(let voice):
            String(localized: "Change Voice to \(voice.name)", bundle: .module)
        }
    }

    /// The short tag on a library card.
    public var tag: String {
        switch self {
        case .upscale: String(localized: "Upscale", bundle: .module)
        case .removeBackground: String(localized: "Cutout", bundle: .module)
        case .reframe: String(localized: "Reframe", bundle: .module)
        case .dub: String(localized: "Dub", bundle: .module)
        case .changeVoice: String(localized: "Voice", bundle: .module)
        }
    }

    /// "Upscaled from rooftop", for the result an operation made from `parent`.
    public func madeFrom(_ parent: String) -> String {
        switch self {
        case .upscale: String(localized: "Upscaled from \(parent)", bundle: .module)
        case .removeBackground: String(localized: "Background removed from \(parent)", bundle: .module)
        case .reframe: String(localized: "Reframed from \(parent)", bundle: .module)
        case .dub: String(localized: "Dubbed from \(parent)", bundle: .module)
        case .changeVoice: String(localized: "Voice changed from \(parent)", bundle: .module)
        }
    }
}

extension PostAction.Kind {
    /// The sheet's title before its options are chosen.
    public var title: String {
        switch self {
        case .upscale: String(localized: "Upscale", bundle: .module)
        case .reframe: String(localized: "Reframe", bundle: .module)
        case .removeBackground: String(localized: "Remove Background", bundle: .module)
        case .dub: String(localized: "Dub", bundle: .module)
        case .changeVoice: String(localized: "Change Voice", bundle: .module)
        }
    }
}

extension DubLanguage {
    /// The language's name in `locale` ("French", "французский"); the code when the system has no name for it.
    public func title(locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: rawValue) ?? rawValue
    }

    /// Every language, by its name in `locale`.
    public static func sorted(locale: Locale = .current) -> [DubLanguage] {
        allCases.sorted {
            $0.title(locale: locale).localizedStandardCompare($1.title(locale: locale)) == .orderedAscending
        }
    }
}

extension AccountVoice {
    /// "Yours" for a voice of the account (a reference element), "Built-in" for the provider's own.
    public var kindLabel: String {
        choice.type == "element"
            ? String(localized: "Yours", bundle: .module) : String(localized: "Built-in", bundle: .module)
    }
}

/// The canvas Reframe makes around a result: the smallest frame of the new aspect ratio that holds the whole
/// result, which sits in its middle; the rest is filled in.
public struct ReframeCanvas: Sendable, Hashable {
    /// The canvas's width over its height.
    public var widthOverHeight: Double
    /// Where the result sits in the canvas, as fractions of the canvas's width and height.
    public var frameX: Double
    public var frameY: Double
    public var frameWidth: Double
    public var frameHeight: Double

    /// `nil` for a result of unknown size.
    public init?(source: PixelSize, aspect: ReframeAspect) {
        guard source.width > 0, source.height > 0 else { return nil }
        let sourceRatio = Double(source.width) / Double(source.height)
        let target = aspect.widthOverHeight
        widthOverHeight = target
        if target >= sourceRatio {
            // Wider canvas: the result keeps its height, the sides are filled.
            frameHeight = 1
            frameWidth = sourceRatio / target
        } else {
            // Taller canvas: the result keeps its width, top and bottom are filled.
            frameWidth = 1
            frameHeight = target / sourceRatio
        }
        frameX = (1 - frameWidth) / 2
        frameY = (1 - frameHeight) / 2
    }

    /// Whether the result already has this aspect ratio, so nothing would be filled in.
    public var isUnchanged: Bool {
        abs(frameWidth - 1) < 0.01 && abs(frameHeight - 1) < 0.01
    }
}

extension UpscaleTarget {
    public var title: String {
        switch self {
        case .p1080: "1080p"
        case .k2: "2K"
        case .k4: "4K"
        }
    }
}

extension UpscaleFrameRate {
    public var title: String {
        switch self {
        case .keep: String(localized: "Keep", bundle: .module)
        default: String(localized: "\(rawValue) fps", bundle: .module)
        }
    }
}

extension UpscaleEngine {
    public var title: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: .module)
        case .topaz: "Topaz"
        }
    }
}

/// Whether a result's page shows the Enhance menu, and whether its items can run.
public enum EnhanceAvailability: Sendable, Hashable {
    case hidden
    /// Shown with every item off, for `reason`.
    case disabled(reason: String)
    case available

    /// - Parameters:
    ///   - connection: the active connection's kind; `nil` while disconnected.
    ///   - offered: whether the account's operations are confirmed (`HiggsfieldMCPProvider.offersPostOperations`).
    public static func of(_ item: LibraryItemModel, connection: ProviderKind?, offered: Bool) -> EnhanceAvailability {
        guard item.outputFile != nil, !item.needsImport, let connection else { return .hidden }
        switch connection {
        case .apiKey:
            // The REST API has neither operation: the menu only says what it takes, on a result an account made.
            return item.job.providerKind == .account ? .disabled(reason: PostOperationText.needsAccount) : .hidden
        case .account:
            return offered ? .available : .disabled(reason: PostOperationText.waitingForCatalog)
        }
    }
}

extension Job {
    /// The spec of `action` on this result: its downloaded file as the source, whole. A result the signed-in
    /// account (`owner`) made is named by its job ID, so nothing is uploaded; any other is uploaded. `nil` without a
    /// downloaded result.
    /// - Parameters:
    ///   - duration, pixelSize: the file's own, when probed just now; otherwise `outputDuration` and `outputPixelSize`.
    public func operationSpec(
        _ action: PostAction, owner: String?, duration: TimeInterval? = nil, pixelSize: PixelSize? = nil
    ) -> JobSpec? {
        guard let file = outputFile, file.isFileURL else { return nil }
        let length = max(0, duration ?? outputDuration)
        let size = pixelSize ?? outputPixelSize ?? PixelSize(width: 0, height: 0)
        let jobID = providerKind == .account && self.owner == owner ? remote?.requestID : nil
        return JobSpec(
            mode: spec.mode, model: spec.model,
            source: SourceClip(fileURL: file, duration: length, pixelSize: size, range: 0...length),
            resolution: spec.resolution, operation: PostOperation(action: action, sourceJobID: jobID))
    }
}
