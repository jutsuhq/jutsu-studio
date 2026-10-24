import Foundation
import JutsuCore

/// One finished job as the library shows it: card texts, details and the specs of follow-up jobs.
public struct LibraryItemModel: Sendable, Hashable, Identifiable {
    public var job: Job
    /// Name of the restyle preset, when the catalog knows it.
    public var presetName: String?
    /// Kept on the stored record, not on the job; for an item only in the account's history, its like.
    public var isStarred: Bool
    /// The account's history item while it isn't in the library yet; its result is downloaded on demand.
    public var historyItem: HistoryItem?

    public var id: UUID { job.id }
    public var spec: JobSpec { job.spec }

    public init(job: Job, presetName: String? = nil, isStarred: Bool = false) {
        self.job = job
        self.presetName = presetName
        self.isStarred = isStarred
        historyItem = nil
    }

    /// A history item not yet in the library, shown as the job it becomes once imported.
    public init(history item: HistoryItem) {
        self.init(job: Job(importing: item, owner: nil, importedAt: item.createdAt))
        historyItem = item
        isStarred = item.isLiked
    }

    /// The generation whose like on the account follows this item's star: the job ID of a result the account
    /// connection made or imported. `nil` for an API key result, whose star stays on this Mac.
    public var likeID: String? {
        guard job.providerKind == .account else { return nil }
        return historyItem?.id ?? job.remote?.requestID
    }

    /// Only on Higgsfield so far: opening, playing or exporting it downloads the result first.
    public var needsImport: Bool { historyItem != nil }

    /// Made outside this app: imported, or still only in the account's history.
    public var isFromHiggsfield: Bool { job.importedAt != nil }

    /// What the card's frame is taken from: the local result, else the remote one.
    public var thumbnailURL: URL? { outputFile ?? historyItem?.outputURL }

    /// The job's `title` when an agent gave one, else the source file name without its extension; the model for a
    /// source only the account has, whose name on the server means nothing. A clip made without a source goes by its
    /// prompt (`JobSpec.name`).
    public var sourceName: String {
        if let title = spec.title { return title }
        guard let url = spec.source?.fileURL else { return spec.name }
        return url.isFileURL ? url.deletingPathExtension().lastPathComponent : spec.model.title
    }

    /// "rooftop · Claymation": the source and the preset, or the mode when there is no preset name.
    public var title: String {
        "\(sourceName) · \(spec.operation?.action.title ?? presetName ?? spec.mode.title)"
    }

    /// "480p · $1.91 · 36 min ago"; without the price, which isn't known, for a video made on Higgsfield.
    public func subtitle(now: Date) -> String {
        let price = isFromHiggsfield ? nil : LibraryFormat.cost(job.price)
        return [spec.resolutionTitle, price, LibraryFormat.ago(finishedAt, now: now)].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "36 min ago · Draft", above the details title.
    public func headline(now: Date) -> String {
        let kind =
            spec.isDraft ? String(localized: "Draft", bundle: .module) : String(localized: "Final", bundle: .module)
        return "\(LibraryFormat.ago(finishedAt, now: now)) · \(kind)"
    }

    /// Short mode tag on the card.
    public var modeTag: String {
        if let operation = spec.operation { return operation.action.tag }
        return switch spec.mode {
        case .motionTransfer: String(localized: "Motion", bundle: .module)
        case .restyle: String(localized: "Restyle", bundle: .module)
        case .objectSwap: String(localized: "Swap", bundle: .module)
        case .edit: String(localized: "Edit", bundle: .module)
        case .extend: String(localized: "Extend", bundle: .module)
        }
    }

    /// The result's length, "6 s": the downloaded file's own, else the selected range or the length asked for.
    public var durationText: String {
        String(localized: "\(Int(job.outputDuration.rounded())) s", bundle: .module)
    }

    /// What VoiceOver reads for the card, everything its tags and badges show:
    /// "rooftop · Claymation, Restyle, Draft, 6 s, 480p · $1.91 · 36 min ago, Starred".
    public func accessibilityLabel(now: Date) -> String {
        [
            title, modeTag, spec.isDraft ? String(localized: "Draft", bundle: .module) : nil, durationText,
            subtitle(now: now),
            isStarred ? String(localized: "Starred", bundle: .module) : nil,
            needsImport ? String(localized: "On Higgsfield, not downloaded yet", bundle: .module) : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    public var finishedAt: Date { job.finishedAt ?? job.createdAt }

    /// The downloaded result; `nil` unless it is a local file.
    public var outputFile: URL? {
        job.outputFile.flatMap { $0.isFileURL ? $0 : nil }
    }

    // MARK: Details

    /// The settings the result was made with, as short chips: "Restyle", "Film Noir", "480p", "6 s", "2 images".
    /// A model other than Genjutsu follows the mode: "Motion transfer", "Seedance 2.5".
    public var facts: [String] {
        var facts = [spec.mode.title]
        if spec.model != .genjutsu { facts.append(spec.model.title) }
        if let presetName { facts.append(presetName) }
        facts += [spec.resolutionTitle, durationText]
        let count = spec.references.count
        if count > 0 { facts.append(String(localized: "\(count) images", bundle: .module)) }
        return facts
    }

    /// The source range sent, "00:04.0 – 00:10.0"; `nil` for a clip made without a source.
    public var rangeText: String? {
        guard let range = spec.source?.range else { return nil }
        return "\(LibraryFormat.timecode(range.lowerBound)) – \(LibraryFormat.timecode(range.upperBound))"
    }

    /// "$1.91 · Estimate · 6 s × $0.318 · API key": the price, where it came from, how it was billed and paid.
    public var billingSummary: String {
        if isFromHiggsfield {
            return String(localized: "Made on Higgsfield · \(job.providerKind.paymentTitle)", bundle: .module)
        }
        return [LibraryFormat.cost(job.price), job.priceSource, billedText, job.providerKind.paymentTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "Queue wait 2:05 · Processing 1:12": the stage times that were recorded; `nil` when none was.
    public var timingSummary: String? {
        let parts = [
            job.queueWait.map { String(localized: "Queue wait \(JobRowModel.duration($0))", bundle: .module) },
            job.processingTime.map { String(localized: "Processing \(JobRowModel.duration($0))", bundle: .module) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Width over height of the downloaded result, else of the source, else the frame a clip made without one asked
    /// for, for sizing the player; `nil` when unknown.
    public var aspectRatio: Double? {
        if let size = job.outputMedia?.pixelSize ?? spec.source?.pixelSize {
            return size.isValid ? Double(size.width) / Double(size.height) : nil
        }
        return spec.aspectRatio?.widthOverHeight
    }

    /// "6 s × $0.318": billed seconds times the rate the stored cost works out to.
    var billedText: String? {
        let seconds = Pricing.billedSeconds(for: spec, on: job.providerKind)
        guard seconds > 0 else { return nil }
        let rate: String
        switch job.price {
        case .usd(let amount, _): rate = LibraryFormat.usd(amount / Decimal(seconds), fractionDigits: 3)
        case .credits(let amount, _): rate = LibraryFormat.credits(amount / Decimal(seconds))
        }
        return "\(seconds) s × \(rate)"
    }

    // MARK: Playback

    /// The result, or the original source limited to the range that was sent. Local files only; a clip made
    /// without a source has no source side.
    public func playback(_ side: PlaybackSide) -> PlaybackClip? {
        switch side {
        case .result:
            return outputFile.map { PlaybackClip(url: $0, range: nil) }
        case .source:
            guard let clip = spec.source, clip.fileURL.isFileURL else { return nil }
            return PlaybackClip(url: clip.fileURL, range: clip.range, bookmark: clip.bookmark)
        }
    }

    // MARK: Follow-up jobs

    /// Only drafts get a final render, once they are in the library: a draft still only on Higgsfield (a native
    /// draft in the account's history) gets its final after it is downloaded.
    public var canRenderFinal: Bool { spec.isDraft && historyItem == nil }
    /// What a final can be rendered at. A Kling draft, made before Kling lost Draft, is Standard, and a Standard
    /// final would cost the same as the draft, so Pro is the only step up.
    public var finalResolutions: [Resolution] {
        spec.model.offersDraft ? [.p720, .p1080] : [KlingQuality.pro.resolution]
    }

    /// The same inputs at `resolution`, as a final; a resolution the item doesn't offer (`finalResolutions`)
    /// becomes the highest it does.
    public func finalSpec(at resolution: Resolution) -> JobSpec {
        var final = spec
        final.resolution = finalResolutions.contains(resolution) ? resolution : finalResolutions.last ?? resolution
        final.isDraft = false
        return final
    }

    /// The final at `resolution`: at 1080p, Higgsfield's finalize of this native draft while the signed-in account
    /// (`owner`) can run it (`Job.finalizeSpec`), else the same inputs rendered again (`finalSpec(at:)`).
    public func finalSpec(at resolution: Resolution, owner: String?, now: Date = Date()) -> JobSpec {
        if resolution == .p1080, let finalize = job.finalizeSpec(owner: owner, now: now) { return finalize }
        return finalSpec(at: resolution)
    }

    /// List price of the final for an API key; `nil` for an account, whose credits only the provider can estimate.
    public func finalPrice(at resolution: Resolution, pricing: Pricing?, connection: ProviderKind?) -> Cost? {
        guard connection == .apiKey, let pricing else { return nil }
        return try? pricing.cost(for: finalSpec(at: resolution))
    }
}

public enum PlaybackSide: String, Sendable, Hashable {
    case result
    case source
}

/// What the details player plays: a local file, optionally limited to a range in seconds.
public struct PlaybackClip: Sendable, Hashable {
    public var url: URL
    public var range: ClosedRange<TimeInterval>?
    /// Security-scoped bookmark of `url`; the source has one, results live in the output folder.
    public var bookmark: Data?

    public init(url: URL, range: ClosedRange<TimeInterval>?, bookmark: Data? = nil) {
        self.url = url
        self.range = range
        self.bookmark = bookmark
    }
}

extension ProviderKind {
    /// How a job was paid, for the billing line.
    public var paymentTitle: String {
        switch self {
        case .apiKey: String(localized: "API key", bundle: .module)
        case .account: String(localized: "Higgsfield account", bundle: .module)
        }
    }
}

/// The confirmation shown before results are deleted. Like a single delete, deleting several moves their files to
/// the Trash and can't be undone in the app.
public enum LibraryDeleteConfirmation {
    public static let title = String(localized: "Delete from library?", bundle: .module)
    public static let message = String(
        localized: "The video file moves to the Trash and its history entry is removed.", bundle: .module)
    public static let confirmTitle = String(localized: "Delete", bundle: .module)

    /// "Delete 3 results from library?"; the single wording for one.
    public static func title(count: Int) -> String {
        count == 1 ? title : String(localized: "Delete \(count) results from library?", bundle: .module)
    }

    public static func message(count: Int) -> String {
        count == 1
            ? message
            : String(
                localized: "The video files move to the Trash and their history entries are removed.",
                bundle: .module)
    }
}
