import Foundation
import HiggsfieldProviders
import JutsuCore
import MediaKit
import Presentation

extension AppEnvironment {
    /// The connection's character sheet service; `nil` without an account, or while its calls aren't confirmed.
    var characterMaker: (any CharacterSheetMaker)? {
        guard HiggsfieldMCPProvider.offersCharacterSheets else { return nil }
        return characterSheets
    }

    /// Whether the account's own list of sheets is read, besides the sheets made in the app.
    var listsAccountCharacterSheets: Bool { HiggsfieldMCPProvider.listsCharacterSheets }

    /// The finished sheets the app made on the signed-in account, newest first.
    var madeCharacterSheets: [CharacterSheet] {
        guard let maker = characterMaker else { return [] }
        return characterBuilder.log.sheets(of: maker.owner)
    }

    /// The account's sheets page by page; `nil` without an account or while that list isn't confirmed.
    func accountCharacterSheetsFeed() -> PagedFeed<CharacterSheet>? {
        guard listsAccountCharacterSheets, let maker = characterMaker else { return nil }
        return PagedFeed(failureTitle: String(localized: "Can't load your characters")) { cursor in
            let page = try await maker.characterSheets(after: cursor)
            return (page.items, page.nextCursor)
        }
    }

    /// The character presets page by page; `nil` without an account.
    func characterPresetsFeed() -> PagedFeed<CharacterPreset>? {
        characterMaker.map { maker in
            PagedFeed(failureTitle: String(localized: "Can't load the presets")) { cursor in
                let page = try await maker.characterPresets(after: cursor)
                return (page.items, page.nextCursor)
            }
        }
    }

    /// Prepares a face or style image like a reference of a job, then uploads it to `maker`.
    func characterUploader(_ maker: any CharacterSheetMaker) -> @Sendable (LocalImage) async throws -> RemoteAsset {
        let preparer = MediaPreparer(workingDirectory: layout.sourcesFolder)
        return { image in
            try await maker.upload(try await preparer.prepareImage(image))
        }
    }

    /// A new connection: the old one's sheets stop being polled, and the new account's sheets still running are
    /// followed again.
    func followCharacterSheets() {
        characterBuilder.reset()
        if let maker = characterMaker { characterBuilder.resume(maker: maker) }
    }

    /// Saves each finished sheet into Library › Images as it arrives, and remembers where.
    static func saveCharacterSheets(of builder: CharacterBuilder, into library: ImageLibrary) {
        builder.onSheets = { [weak builder, weak library] records in
            let sheets = records.compactMap { record in
                record.imageURL.map { url in
                    var image = GeneratedImage(
                        url: url,
                        prompt: record.brief.isEmpty ? String(localized: "Character sheet") : record.brief,
                        model: String(localized: "Character sheet"))
                    image.remote = MaterialRemote(provider: .account, owner: record.owner, id: record.id)
                    image.variantGroupID = record.requestID
                    return (
                        jobID: record.id,
                        image: image
                    )
                }
            }
            let jobIDs = Dictionary(uniqueKeysWithValues: sheets.map { ($0.image.id, $0.jobID) })
            library?.save(sheets.map(\.image)) { image, saved in
                if let jobID = jobIDs[image.id] { builder?.log.setFile(saved.fileURL, for: jobID) }
            }
        }
    }
}
