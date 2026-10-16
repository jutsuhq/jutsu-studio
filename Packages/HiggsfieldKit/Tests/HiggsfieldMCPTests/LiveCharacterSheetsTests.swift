import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// The AI Influencer tools against their live answers of 2026-10-15 (`docs/mcp-snapshots/live-2026-10-15/`): free,
/// read-only calls, replayed by a stub that lists the snapshot's tool schemas.
extension Network {
    @Suite struct LiveCharacterSheets {
        /// A stub answering every call with the live answer `name`.
        static func replay(_ name: String) throws -> (HiggsfieldAccount, StubServer) {
            let live = try CatalogSnapshot.liveAnswer(name)
            let tools = try CharacterSheets.names.map(CatalogSnapshot.tool)
            return Account.account(tools: Account.fullSet + tools) { _, _ in live.answer }
        }

        /// The arguments the live call was made with.
        static func arguments(_ name: String) throws -> JSONValue {
            try CatalogSnapshot.liveAnswer(name).arguments
        }

        @Test func theLiveCallsKeepToTheSnapshotSchemas() throws {
            for name in [
                "ai_influencer_get_options", "ai_influencer_list_presets", "ai_influencer_prepare",
                "assets_picker_list_influencer",
            ] {
                let live = try CatalogSnapshot.liveAnswer(name)
                #expect(try CatalogSnapshot.violations(of: live.arguments, sentTo: live.tool).isEmpty, "\(name)")
            }
        }

        @Test func optionsAreReadWithTheirLabelsAndLimits() async throws {
            let (account, stub) = try Self.replay("ai_influencer_get_options")
            let arguments = try Self.arguments("ai_influencer_get_options")

            let groups = try await account.influencerOptions(tier: "normal")

            #expect(Account.calls(stub).first?["arguments"] == arguments)
            #expect(groups.map(\.id) == ["gender", "ethnicity_origin_base", "proportions", "freak_face", "accessory"])
            #expect(groups.map(\.label) == ["Gender", "Ethnicity", "Proportions", "Features", "Accessories"])
            #expect(groups.map(\.max) == [1, 1, 2, 4, 3])
            #expect(groups.first?.options.map(\.label).first == "Female")
            // Every option the answer gives is offered for `normal`, so none is left out.
            #expect(groups.map(\.options.count) == [5, 6, 4, 10, 6])
        }

        @Test func presetsCarryTheirDesignPreviewAndNextPage() async throws {
            let (account, stub) = try Self.replay("ai_influencer_list_presets")
            let arguments = try Self.arguments("ai_influencer_list_presets")

            let page = try await account.influencerPresets(size: 3)

            #expect(Account.calls(stub).first?["arguments"] == arguments)
            #expect(page.items.count == 3)
            #expect(page.nextCursor == 2)
            let first = try #require(page.items.first)
            #expect(first.name == "AI Influencer 38")
            #expect(first.previewURL?.lastPathComponent.hasPrefix("9252b193") == true)
            let design = try #require(first.design)
            #expect(design.tier == "freak")
            #expect(design.seed == 427_752)
            #expect(design.selection["hair"] == ["hair_bowl"])
            #expect(design.selection["distinctive"] == [])
            #expect(design.brief.hasPrefix("Fashion-editorial"))
            #expect(page.items.allSatisfy { $0.design != nil && $0.unavailableReason == nil })
        }

        @Test func aLastPresetPageEndsTheList() async throws {
            let (account, _) = try Self.replay("ai_influencer_list_presets")
            // Three items where four were asked for: the last page, whatever `cursor` says.
            let page = try await account.influencerPresets(size: 4)
            #expect(page.nextCursor == nil)
        }

        @Test func prepareReadsTheParamsAndTheFractionalPrice() async throws {
            let (account, _) = try Self.replay("ai_influencer_prepare")

            let quote = try await account.prepareInfluencer(InfluencerDesign(tier: nil, batchSize: 1))

            let live = try CatalogSnapshot.liveAnswer("ai_influencer_prepare")
            #expect(quote.credits == 1.125)
            #expect(quote.freeGensRemaining == nil)
            #expect(quote.params == live.answer["params"])
            #expect(quote.params["selection"]?["gender"] == ["female"])
        }

        @Test func theLiveParamsGoToGenerateUnchangedAndKeepToItsSchema() async throws {
            let live = try CatalogSnapshot.liveAnswer("ai_influencer_prepare")
            let params = try #require(live.answer["params"])
            let (account, stub) = Account.account(
                tools: Account.fullSet + (try CharacterSheets.names.map(CatalogSnapshot.tool))
            ) { _, _ in ["submitted": true, "job_id": "job-1", "job_ids": ["job-1"], "credits": .number(1.125)] }

            _ = try await account.generateInfluencer(InfluencerQuote(params: params, credits: 1.125), maxCredits: 1.125)

            #expect(Account.calls(stub).first?["arguments"]?["params"] == params)
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func anAccountWithoutSheetsListsNone() async throws {
            let (account, stub) = try Self.replay("assets_picker_list_influencer")
            let arguments = try Self.arguments("assets_picker_list_influencer")

            let page = try await account.influencerSheets()

            #expect(page.items.isEmpty)
            #expect(page.nextCursor == nil)
            let sent = try #require(Account.calls(stub).first?["arguments"])
            #expect(sent["source"] == arguments["source"])
            #expect(sent["kind"] == arguments["kind"])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }
    }
}
