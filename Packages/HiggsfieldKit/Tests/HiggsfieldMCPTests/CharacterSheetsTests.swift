import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// The AI Influencer character sheet tools, against the tool schemas of the catalog snapshot of 2026-10-15. The answers
/// are in the shape of the tools' `outputSchema`s; `LiveCharacterSheets` replays the live ones.
extension Network {
    @Suite struct CharacterSheets {
        static let names = [
            "ai_influencer_get_options", "ai_influencer_list_presets", "ai_influencer_prepare",
            "ai_influencer_generate", "assets_picker_list",
        ]
        static let face = "9b2e4c1a-7d3f-4a8b-8c6d-1e2f3a4b5c6d"
        static let style = "5a6b7c8d-1e2f-4a3b-9c4d-5e6f7a8b9c0d"
        static let sheet = "1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d"
        static let jobs = ["0f1e2d3c-4b5a-4968-8776-655443322110", "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"]

        /// Exact params as `ai_influencer_prepare`'s `outputSchema` describes them.
        static let params: JSONValue = [
            "tier": "normal", "selection": ["hair": ["curly"], "eyes": ["green"]], "brief": "a street magician",
            "seed": 4242, "batch_size": 2,
            "medias": [["role": "image", "data": ["id": .string(face), "type": "media_input"]]],
            "item_medias": [["role": "image", "data": ["id": .string(sheet), "type": "image_job"]]],
        ]

        static func account(
            tools names: [String] = names,
            _ reply: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) throws -> (HiggsfieldAccount, StubServer) {
            Account.account(tools: Account.fullSet + (try names.map(CatalogSnapshot.tool)), call: reply)
        }

        @Test func everyToolIsFoundByItsSnapshotSchema() throws {
            let catalog = ToolCatalog(
                try Self.names.map { try CatalogSnapshot.tool($0).decode(MCPTool.self) })
            for role in [ToolRole.influencerOptions, .influencerPresets, .influencerPrepare, .influencerGenerate] {
                #expect(catalog[role] != nil)
            }
        }

        @Test func optionsAreReadPerTierWithTheirLimits() async throws {
            let (account, stub) = try Self.account { _, _ in
                [
                    "tiers": ["normal", "freak", "total", "cats"],
                    "groups": [
                        [
                            "id": "hair", "label": "Hair", "max": 2,
                            "options": [
                                ["id": "curly", "label": "Curly", "slot": .null, "tiers": ["normal", "freak"]],
                                ["id": "fur", "label": "Fur", "slot": "body", "tiers": ["cats"]],
                            ],
                        ],
                        ["label": "No ID", "max": 1, "options": []],
                    ],
                ]
            }

            let groups = try await account.influencerOptions(tier: "normal")

            #expect(
                groups == [
                    InfluencerTraitGroup(
                        id: "hair", label: "Hair", max: 2,
                        options: [.init(id: "curly", label: "Curly", tiers: ["normal", "freak"])])
                ])
            #expect(
                Account.calls(stub) == [["name": "ai_influencer_get_options", "arguments": ["tier": "normal"]]])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func presetsCarryTheDesignThatRecreatesThem() async throws {
            let (account, stub) = try Self.account { _, _ in
                [
                    "total": 41, "cursor": 2,
                    "items": [
                        [
                            "id": .string(Self.sheet), "name": "Neon Rider", "priority": 3,
                            "preview": ["url": "https://cdn.higgsfield.ai/p.webp"],
                            "sheet": ["url": "https://cdn.higgsfield.ai/s.png"],
                            "recreate": [
                                "job_set_type": "ai_influencer_sheet",
                                "params": [
                                    "tier": "total", "selection": ["hair": ["neon"]], "brief": "rides at night",
                                    "seed": 77, "medias": [],
                                ],
                            ],
                            "recreate_unavailable_reason": .null,
                        ],
                        [
                            "id": .string(Self.style), "name": "Locked", "priority": 1,
                            "preview": ["url": "https://cdn.higgsfield.ai/l.webp"],
                            "sheet": ["url": "https://cdn.higgsfield.ai/l.png"], "recreate": .null,
                            "recreate_unavailable_reason": "Made with a reference",
                        ],
                    ],
                ]
            }

            let page = try await account.influencerPresets(cursor: 1, size: 2)

            #expect(page.nextCursor == 2)
            #expect(
                page.items.first?.design
                    == InfluencerPreset.Design(
                        tier: "total", selection: ["hair": ["neon"]], brief: "rides at night", seed: 77))
            #expect(page.items.first?.previewURL == URL(string: "https://cdn.higgsfield.ai/p.webp"))
            #expect(page.items.last?.design == nil)
            #expect(page.items.last?.unavailableReason == "Made with a reference")
            #expect(
                Account.calls(stub) == [
                    ["name": "ai_influencer_list_presets", "arguments": ["size": 2, "cursor": 1]]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func prepareSendsTheDesignAndReadsTheExactParamsAndPrice() async throws {
            let (account, stub) = try Self.account { _, _ in
                ["params": Self.params, "credits": .number(12.5), "free_gens_remaining": 0, "submitted": false]
            }
            let design = InfluencerDesign(
                tier: "normal", selection: ["hair": ["curly", "a", "b", "c", "d"], "eyes": []],
                brief: "a street magician", seed: 4242, batchSize: 2,
                identity: InfluencerImage(id: Self.face, kind: .mediaInput),
                styles: [InfluencerImage(id: Self.sheet, kind: .imageJob)], randomize: false)

            let quote = try await account.prepareInfluencer(design)

            #expect(quote == InfluencerQuote(params: Self.params, credits: 12.5, freeGensRemaining: 0))
            let arguments = try #require(Account.calls(stub).first?["arguments"])
            #expect(arguments["selection"] == ["hair": ["curly", "a", "b", "c"]])
            #expect(arguments["randomize"] == false)
            #expect(arguments["batch_size"] == 2)
            let identity: JSONValue = ["role": "image", "data": ["id": .string(Self.face), "type": "media_input"]]
            let style: JSONValue = ["role": "image", "data": ["id": .string(Self.sheet), "type": "image_job"]]
            #expect(arguments["medias"] == [identity])
            #expect(arguments["item_medias"] == [style])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aRandomDesignLeavesTheTierAndSeedToTheServer() async throws {
            let (account, stub) = try Self.account { _, _ in ["params": Self.params, "credits": 6, "submitted": false] }

            _ = try await account.prepareInfluencer(InfluencerDesign(tier: nil, batchSize: 9))

            let arguments = try #require(Account.calls(stub).first?["arguments"])
            #expect(
                arguments
                    == [
                        "selection": [:], "brief": "", "batch_size": 4, "medias": [], "item_medias": [],
                        "randomize": true,
                    ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aQuoteWithoutParamsOrPriceGivesTheReason() async throws {
            let (account, _) = try Self.account { _, _ in ["error": "Unknown trait"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Unknown trait")) {
                try await account.prepareInfluencer(InfluencerDesign(tier: "normal"))
            }
        }

        @Test func generateSendsTheQuoteUnchangedWithItsPriceAsTheCap() async throws {
            let (account, stub) = try Self.account { _, _ in
                [
                    "submitted": true, "job_id": .string(Self.jobs[0]),
                    "job_ids": .array(Self.jobs.map(JSONValue.string)),
                    "credits": .number(12.5), "use_free_gens": false, "results": [],
                ]
            }

            let submission = try await account.generateInfluencer(
                InfluencerQuote(params: Self.params, credits: 12.5), maxCredits: 12.5)

            #expect(submission == InfluencerSubmission(jobIDs: Self.jobs, credits: 12.5))
            #expect(
                Account.calls(stub)
                    == [
                        [
                            "name": "ai_influencer_generate",
                            "arguments": ["params": Self.params, "max_credits": .number(12.5)],
                        ]
                    ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aRefusedSubmitGivesTheReason() async throws {
            let (account, _) = try Self.account { _, _ in
                ["submitted": false, "credits": 14, "error": "Price is above max_credits"]
            }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Price is above max_credits")) {
                try await account.generateInfluencer(InfluencerQuote(params: Self.params, credits: 12), maxCredits: 12)
            }
        }

        @Test func aSubmitAnswerWithoutJobsMayHaveStartedSome() async throws {
            let (account, stub) = try Self.account { _, _ in ["submitted": true] }
            await #expect(throws: HiggsfieldError.server(status: 200)) {
                try await account.generateInfluencer(InfluencerQuote(params: Self.params, credits: 12), maxCredits: 12)
            }
            // Sent once, never again.
            #expect(Account.calls(stub).count == 1)
        }

        @Test func sheetsAreListedFromTheInfluencerSource() async throws {
            let (account, stub) = try Self.account { _, _ in
                [
                    "items": [
                        [
                            "id": .string(Self.jobs[0]), "kind": "image", "url": "https://cdn.higgsfield.ai/sheet.png",
                            "thumbnailUrl": "https://cdn.higgsfield.ai/sheet-small.png", "createdAt": 1_760_000_000,
                        ]
                    ],
                    "next_cursor": .null,
                ]
            }

            let page = try await account.influencerSheets()

            #expect(page.items.map(\.id) == [Self.jobs[0]])
            #expect(page.nextCursor == nil)
            #expect(
                Account.calls(stub).first?["arguments"] == ["source": "influencer", "kind": "image", "size": 30])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aMissingToolIsReportedWithoutACall() async throws {
            let (account, stub) = try Self.account(tools: [])
            await #expect(throws: HiggsfieldError.toolUnavailable("ai_influencer_prepare")) {
                try await account.prepareInfluencer(InfluencerDesign(tier: nil))
            }
            #expect(Account.calls(stub).isEmpty)
        }
    }
}
