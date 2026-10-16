import Foundation
import JutsuCore
import Observation

/// One character sheet job the app started: kept from the moment its submit was answered, so a job that is paid for is
/// never lost track of, through a quit or a sign-out.
public struct CharacterSheetRecord: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        case pending
        case completed
        case failed(String?)
        case rejected
    }

    /// The provider's job ID.
    public var id: String
    /// `GenerationProvider.owner` of the account that started it.
    public var owner: String?
    /// The request it came from, which is also its `ImageCharge`'s ID; one request makes up to four sheets.
    public var requestID: UUID
    public var createdAt: Date
    public var brief: String
    public var state: State
    /// Where the provider serves the finished sheet; its links expire.
    public var imageURL: URL?
    /// The copy saved in Library › Images.
    public var fileURL: URL?

    public init(
        id: String, owner: String?, requestID: UUID, createdAt: Date, brief: String, state: State = .pending,
        imageURL: URL? = nil, fileURL: URL? = nil
    ) {
        self.id = id
        self.owner = owner
        self.requestID = requestID
        self.createdAt = createdAt
        self.brief = brief
        self.state = state
        self.imageURL = imageURL
        self.fileURL = fileURL
    }

    /// The finished sheet as the Characters source lists it; `nil` until it is finished.
    public var sheet: CharacterSheet? {
        guard state == .completed, let imageURL else { return nil }
        return CharacterSheet(id: id, imageURL: imageURL, createdAt: createdAt, fileURL: fileURL)
    }
}

/// The character sheet jobs the app started (`CharacterSheetRecord`), kept in `character-sheets.json` next to the
/// store. The Characters source lists these first, before the account's own list, and a job still running after a
/// quit is followed again from here. Records that can't be read are left out and their file kept aside (`LogFile`).
///
/// A write that fails keeps the records in memory, so their jobs are still followed in this launch, says why in
/// `saveError` and lists the job IDs only this launch knows in `unsavedIDs`, for the user to copy. The next change or
/// `retrySave` writes everything again.
@MainActor
@Observable
public final class CharacterSheetLog {
    public static let fileName = "character-sheets.json"

    /// Oldest first.
    public private(set) var records: [CharacterSheetRecord]
    /// Why the last write failed; `nil` once one goes through.
    public private(set) var saveError: LogWriteError?
    /// Jobs added since the last write that went through: a quit would lose track of them.
    public private(set) var unsavedIDs: [String] = []
    @ObservationIgnored private let file: LogFile<CharacterSheetRecord>

    /// - Parameter folder: where the file lives; `nil` keeps everything in memory, as tests and previews do.
    public init(folder: URL?) {
        file = LogFile(folder: folder, name: Self.fileName)
        records = file.read()
    }

    /// The finished sheets of `owner`, newest first.
    public func sheets(of owner: String?) -> [CharacterSheet] {
        records.filter { $0.owner == owner }.reversed().compactMap(\.sheet)
    }

    /// The jobs of `owner` still running.
    public func pending(of owner: String?) -> [CharacterSheetRecord] {
        records.filter { $0.owner == owner && $0.state == .pending }
    }

    public func add(_ new: [CharacterSheetRecord]) {
        let added = new.filter { record in !records.contains { $0.id == record.id } }
        records += added
        unsavedIDs += added.map(\.id)
        save()
    }

    public func update(_ id: String, state: CharacterSheetRecord.State, imageURL: URL? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        if let imageURL { records[index].imageURL = imageURL }
        save()
    }

    /// Where the finished sheet was saved.
    public func setFile(_ fileURL: URL, for id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].fileURL = fileURL
        save()
    }

    /// Writes the records again after `saveError`.
    public func retrySave() {
        save()
    }

    private func save() {
        do {
            try file.write(records)
            saveError = nil
            unsavedIDs = []
        } catch {
            saveError = error
        }
    }
}
