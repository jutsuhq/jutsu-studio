import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

/// Maps the account's AI Influencer designs, presets and generated sheets.
enum AccountCharacters {
    static func group(_ group: InfluencerTraitGroup) -> CharacterTraitGroup {
        CharacterTraitGroup(
            id: group.id, title: group.label, maxPicks: group.max,
            traits: group.options.map { CharacterTrait(id: $0.id, title: $0.label) })
    }

    static func preset(_ preset: InfluencerPreset) -> CharacterPreset {
        let settings = preset.design.flatMap { design in
            CharacterTier(rawValue: design.tier).map { tier in
                CharacterPresetSettings(tier: tier, traits: design.selection, brief: design.brief, seed: design.seed)
            }
        }
        return CharacterPreset(
            id: preset.id, name: preset.name, previewURL: preset.previewURL ?? preset.sheetURL, settings: settings,
            unavailableReason: settings == nil
                ? preset.unavailableReason ?? String(localized: "This preset can't be made again.", bundle: .module)
                : nil)
    }

    static func sheet(_ asset: AccountAsset) -> CharacterSheet {
        CharacterSheet(id: asset.id, imageURL: asset.url, thumbnailURL: asset.thumbnailURL, createdAt: asset.createdAt)
    }

    /// The design as `ai_influencer_prepare` takes it: uploads as `media_input`. An image without a media ID can't be
    /// named, so it is refused before anything is sent.
    static func design(_ design: CharacterDesign) throws -> InfluencerDesign {
        guard CharacterDesign.sheetCounts.contains(design.count) else {
            throw ProviderError.validation(
                field: "count", message: String(localized: "Make 1 to 4 sheets.", bundle: .module))
        }
        guard design.styles.count <= CharacterDesign.maxStyles else {
            throw ProviderError.validation(
                field: nil, message: String(localized: "Use at most 3 style references.", bundle: .module))
        }
        func image(_ asset: RemoteAsset) throws -> InfluencerImage {
            guard let id = asset.id else {
                throw ProviderError.validation(
                    field: nil,
                    message: String(localized: "Unexpected result from the media_upload tool", bundle: .module))
            }
            return InfluencerImage(id: id, kind: .mediaInput)
        }
        return InfluencerDesign(
            tier: design.tier?.rawValue, selection: design.traits, brief: design.brief, seed: design.seed,
            batchSize: design.count, identity: try design.face.map(image), styles: try design.styles.map(image),
            randomize: design.randomize)
    }

    static func quote(_ quote: InfluencerQuote, count: Int) throws -> CharacterQuote {
        CharacterQuote(credits: quote.credits, count: count, request: try JSONEncoder().encode(quote.params))
    }

    static func influencerQuote(_ quote: CharacterQuote) throws -> InfluencerQuote {
        InfluencerQuote(params: try JSONDecoder().decode(JSONValue.self, from: quote.request), credits: quote.credits)
    }

    static func status(_ status: GenerationStatus) -> ImageJobStatus {
        switch status {
        case .queued, .inProgress: .pending
        case .completed(let url) where url.isHTTPS: .completed([url])
        case .completed:
            .failed(message: String(localized: "The result isn't on a secure (https) address.", bundle: .module))
        case .failed(let message): .failed(message: message)
        case .rejected(let moderation): .rejected(Rejection(moderation))
        case .canceled: .canceled
        }
    }
}

extension HiggsfieldMCPProvider: CharacterSheetMaker {
    public static var offersCharacterSheets: Bool { true }
    public static var listsCharacterSheets: Bool { true }

    public func characterTraits(for tier: CharacterTier) async throws -> [CharacterTraitGroup] {
        let groups = try await mapped { try await account.influencerOptions(tier: tier.rawValue) }
        return groups.filter { !$0.options.isEmpty }.map(AccountCharacters.group)
    }

    public func characterPresets(after cursor: HistoryCursor?) async throws -> CharacterPresetPage {
        let page = try await mapped {
            try await account.influencerPresets(cursor: cursor.flatMap { Int($0.value) }, size: Self.presetPageSize)
        }
        return CharacterPresetPage(
            items: page.items.map(AccountCharacters.preset),
            nextCursor: page.nextCursor.map { HistoryCursor(String($0)) })
    }

    public func characterSheets(after cursor: HistoryCursor?) async throws -> CharacterSheetPage {
        let page = try await mapped {
            try await account.influencerSheets(
                cursor: cursor.flatMap(HistoryMapping.cursorValue), size: Self.sheetPageSize)
        }
        let next = page.items.isEmpty ? nil : page.nextCursor.flatMap(HistoryMapping.cursor)
        return CharacterSheetPage(items: page.items.map(AccountCharacters.sheet), nextCursor: next)
    }

    public func quoteCharacters(_ design: CharacterDesign) async throws -> CharacterQuote {
        let request = try AccountCharacters.design(design)
        let quote = try await mapped { try await account.prepareInfluencer(request) }
        return try AccountCharacters.quote(quote, count: design.count)
    }

    /// `max_credits` is the quote's own price, so the server refuses the submit when the price went up since. Sent
    /// once: any failure once the call may have reached the server, a cancel during it included, throws
    /// `outcomeUnknown`.
    public func generateCharacters(_ quote: CharacterQuote) async throws -> [RemoteJob] {
        let request = try AccountCharacters.influencerQuote(quote)
        try Task.checkCancellation()
        let submission: InfluencerSubmission
        do {
            submission = try await account.generateInfluencer(request, maxCredits: quote.credits)
        } catch let error as HiggsfieldError {
            throw Self.mayHaveReachedServer(error) ? ProviderError.outcomeUnknown : ProviderError(error)
        } catch is CancellationError {
            throw ProviderError.outcomeUnknown
        }
        return submission.jobIDs.map { RemoteJob(requestID: $0) }
    }

    /// One `jobs_wait` for up to 12 jobs; the jobs it doesn't answer for, or all of them when it can't be used, are
    /// asked with `job_status` one by one. A job whose status can't be read is left out.
    public func characterSheetStatuses(_ jobs: [RemoteJob]) async throws -> [String: ImageJobStatus] {
        let ids = jobs.map(\.requestID)
        var statuses: [String: ImageJobStatus] = [:]
        if ids.count <= HiggsfieldAccount.jobsWaitLimit,
            let answer = try? await account.waitForJobs(ids)
        {
            statuses = answer.statuses.mapValues(AccountCharacters.status)
        }
        for id in ids where statuses[id] == nil {
            try Task.checkCancellation()
            guard let status = try? await account.imageStatus(of: id) else { continue }
            statuses[id] = ImageJobStatus(status)
        }
        return statuses
    }

    static let presetPageSize = 30
    static let sheetPageSize = 30
}
