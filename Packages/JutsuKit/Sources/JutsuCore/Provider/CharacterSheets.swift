import Foundation

/// A provider whose account makes character sheets: a generated image of one character from several sides, which a
/// video job then uses as a reference image. A small service beside `GenerationProvider`, like `ImageProvider`: its
/// jobs never enter the job engine; whoever submits them tracks every job and polls it.
public protocol CharacterSheetMaker: Sendable {
    /// `GenerationProvider.owner` of the account, which a sheet's media belongs to.
    var owner: String? { get }
    /// The trait groups of `tier`, each with the options that tier offers.
    func characterTraits(for tier: CharacterTier) async throws -> [CharacterTraitGroup]
    func characterPresets(after cursor: HistoryCursor?) async throws -> CharacterPresetPage
    /// The account's sheets, newest first, wherever they were made. Throws when the provider can't list them.
    func characterSheets(after cursor: HistoryCursor?) async throws -> CharacterSheetPage
    /// A face or style image of a design.
    func upload(_ file: PreparedFile) async throws -> RemoteAsset
    /// The exact request and its price; free, starts nothing. A design left to chance comes back different each time.
    func quoteCharacters(_ design: CharacterDesign) async throws -> CharacterQuote
    /// Starts `quote`'s sheets, one job each, refused when the price went above the quote's. Not idempotent: a submit
    /// that may have reached the provider throws `ProviderError.outcomeUnknown` and must never be sent again.
    func generateCharacters(_ quote: CharacterQuote) async throws -> [RemoteJob]
    /// The statuses of `jobs` by request ID; a job left out is still running as far as is known.
    func characterSheetStatuses(_ jobs: [RemoteJob]) async throws -> [String: ImageJobStatus]
}

/// Who a character is: a person, or an animal of one kind.
public enum CharacterTier: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case normal
    case freak
    case total
    case insects
    case frogs
    case cats
    case dogs
    case capybaras
    case birds

    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
        case human
        case animal

        public var id: Self { self }

        public var tiers: [CharacterTier] { CharacterTier.allCases.filter { $0.kind == self } }
    }

    public var id: Self { self }

    public var kind: Kind {
        switch self {
        case .normal, .freak, .total: .human
        case .insects, .frogs, .cats, .dogs, .capybaras, .birds: .animal
        }
    }
}

/// A group of traits a design picks from: "Hair", "Eyes"…
public struct CharacterTraitGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// How many of `traits` one design takes.
    public var maxPicks: Int
    public var traits: [CharacterTrait]

    public init(id: String, title: String, maxPicks: Int, traits: [CharacterTrait]) {
        self.id = id
        self.title = title
        self.maxPicks = max(maxPicks, 1)
        self.traits = traits
    }
}

public struct CharacterTrait: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A ready-made character, with the settings that make it again when the provider gives them.
public struct CharacterPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var previewURL: URL?
    /// `nil` when it can't be made again; `unavailableReason` says why.
    public var settings: CharacterPresetSettings?
    public var unavailableReason: String?

    public init(
        id: String, name: String, previewURL: URL?, settings: CharacterPresetSettings?, unavailableReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.previewURL = previewURL
        self.settings = settings
        self.unavailableReason = unavailableReason
    }
}

public struct CharacterPresetSettings: Sendable, Hashable {
    public var tier: CharacterTier
    /// Trait IDs by group ID.
    public var traits: [String: [String]]
    public var brief: String
    public var seed: Int?

    public init(tier: CharacterTier, traits: [String: [String]], brief: String, seed: Int?) {
        self.tier = tier
        self.traits = traits
        self.brief = brief
        self.seed = seed
    }
}

public struct CharacterPresetPage: Sendable, Hashable {
    public var items: [CharacterPreset]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [CharacterPreset], nextCursor: HistoryCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// What a character is to look like, as the provider is asked to price it.
public struct CharacterDesign: Sendable, Hashable {
    public static let sheetCounts = 1...4
    public static let maxStyles = 3
    public static let maxBrief = 4000

    /// `nil` leaves it to chance.
    public var tier: CharacterTier?
    /// Trait IDs by group ID.
    public var traits: [String: [String]]
    public var brief: String
    public var seed: Int?
    /// Sheets to make, `sheetCounts`.
    public var count: Int
    /// The uploaded face to keep.
    public var face: RemoteAsset?
    /// Uploaded style references, at most `maxStyles`.
    public var styles: [RemoteAsset]
    /// Fill the traits left unset at random.
    public var randomize: Bool

    public init(
        tier: CharacterTier?, traits: [String: [String]] = [:], brief: String = "", seed: Int? = nil, count: Int = 1,
        face: RemoteAsset? = nil, styles: [RemoteAsset] = [], randomize: Bool = true
    ) {
        self.tier = tier
        self.traits = traits
        self.brief = brief
        self.seed = seed
        self.count = count
        self.face = face
        self.styles = styles
        self.randomize = randomize
    }
}

/// The provider's exact request for a design and its price.
public struct CharacterQuote: Sendable, Hashable {
    /// The price of every sheet together, exact: the submit is refused above it.
    public var credits: Double
    public var count: Int
    /// What the provider sends to generate, unchanged; only the provider reads it.
    public var request: Data

    public init(credits: Double, count: Int, request: Data) {
        self.credits = credits
        self.count = count
        self.request = request
    }

    public var cost: Cost { .credits(Decimal(shortestOf: credits) ?? 0, isEstimate: false) }
}

/// A finished character sheet of the account: an image job.
public struct CharacterSheet: Sendable, Hashable, Identifiable {
    /// The job ID, which a job of the same account names instead of uploading the image.
    public var id: String
    public var imageURL: URL
    public var thumbnailURL: URL?
    public var createdAt: Date?
    /// The copy saved on this Mac, for a sheet made in the app; the provider's links expire.
    public var fileURL: URL?

    public init(
        id: String, imageURL: URL, thumbnailURL: URL? = nil, createdAt: Date? = nil, fileURL: URL? = nil
    ) {
        self.id = id
        self.imageURL = imageURL
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.fileURL = fileURL
    }
}

public struct CharacterSheetPage: Sendable, Hashable {
    public var items: [CharacterSheet]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [CharacterSheet], nextCursor: HistoryCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
