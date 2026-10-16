import Foundation
import JutsuCore
import Observation

/// The prices of reference image requests and virality scores (`ImageCharge`), kept in a file of their own next to
/// the store: neither enters the job store, so the daily cap and Spending read these beside the jobs. Requests older than
/// Spending's longest period are dropped when the file is read. An unreadable file stays intact and blocks new
/// charges until repaired; a partial history must not pass the daily cap.
///
/// A price is added before its request is sent, and `add` throws when it can't be written: a paid request never goes
/// out with a price only this launch knows. A settle or removal that can't be written stays in memory, is said in
/// `saveError`, and is written with the next change or `retrySave`.
@MainActor
@Observable
public final class ImageSpendLog {
    public static let fileName = "image-spend.json"
    /// Spending looks back 30 days; one more keeps a request sent just before midnight.
    static let keptDays = 31

    public private(set) var charges: [ImageCharge]
    /// Why the last write failed; `nil` once one goes through.
    public private(set) var saveError: LogWriteError?
    public private(set) var readError: LogWriteError?
    @ObservationIgnored private let file: LogFile<ImageCharge>

    /// - Parameter folder: where the file lives; `nil` keeps everything in memory, as tests and previews do.
    public init(folder: URL?, now: Date = .now, calendar: Calendar = .current) {
        file = LogFile(folder: folder, name: Self.fileName)
        let start =
            calendar.date(byAdding: .day, value: -Self.keptDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        do {
            charges = try file.readStrict().filter { $0.date >= start }
        } catch {
            charges = []
            readError = error
            saveError = error
        }
    }

    /// Counts from now: a request is added before it is submitted. A price that can't be written isn't counted
    /// either, and its request must not be sent.
    public func add(_ charge: ImageCharge) throws(LogWriteError) {
        charges.append(charge)
        do {
            try save()
        } catch {
            charges.removeAll { $0.id == charge.id }
            throw error
        }
    }

    /// The request finished with images, so it was charged at its price, or at `cost` when the answer named
    /// what it charged.
    public func settle(_ id: UUID, at cost: Cost? = nil) {
        guard let index = charges.firstIndex(where: { $0.id == id }) else { return }
        charges[index].isPending = false
        if let cost { charges[index].cost = cost }
        // The change stands in memory either way; a failed write is kept in `saveError` for the user.
        try? save()
    }

    /// The request wasn't charged: refused, failed, or cancelled while queued.
    public func remove(_ id: UUID) {
        charges.removeAll { $0.id == id }
        try? save()
    }

    /// Writes the charges again after `saveError`.
    public func retrySave() {
        if readError != nil {
            do {
                charges = try file.readStrict()
                readError = nil
            } catch {
                readError = error
                saveError = error
                return
            }
        }
        try? save()
    }

    private func save() throws(LogWriteError) {
        if let readError { throw readError }
        do {
            try file.write(charges)
            saveError = nil
        } catch {
            saveError = error
            throw error
        }
    }

    /// Why a request whose price couldn't be written wasn't sent.
    public static func notSent(_ error: LogWriteError) -> String {
        String(
            localized: "Nothing was sent: Jutsu Studio couldn't save the price first. \(error.reason)", bundle: .module)
    }
}

/// Today's spend and the cap of a connection of `ProviderKind`, as the daily cap counts them right now: the jobs and
/// the `ImageSpendLog`. `nil` when that connection has no cap.
public typealias SpendStatusReader = @MainActor (ProviderKind) async throws -> SpendStatus?

/// What a paid request outside the job queue (Generate…, Create Character, Score Variants) did about today's cap.
/// Each one reads today's spend itself right before it is sent, as `JobEngine.enqueue` does, so a check a screen made
/// earlier can't let it through.
public enum PaidStart: Sendable, Hashable {
    case started
    /// It would take today past the cap, or its price isn't known under one: nothing was sent. Asked again with
    /// `overCapApproved` once the user agrees.
    case needsConfirmation(CapConfirmation)
    /// Nothing to send: the form can't run, or another request or connection came first.
    case notStarted
}
