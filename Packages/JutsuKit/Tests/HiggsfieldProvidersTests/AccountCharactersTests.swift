import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Character sheets on the account, with the tool definitions of the catalog snapshot of 2026-10-15 and answers in
    /// the shape of their `outputSchema`s. Every call the stub gets is checked against the snapshot's schema.
    @Suite struct AccountCharactersProvider {
        static let face = "9b2e4c1a-7d3f-4a8b-8c6d-1e2f3a4b5c6d"
        static let jobs = ["0f1e2d3c-4b5a-4968-8776-655443322110", "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"]
        static let params: JSONValue = [
            "tier": "cats", "selection": ["fur": ["ginger"]], "brief": "a sleepy chef", "seed": 12, "batch_size": 2,
            "medias": [["role": "image", "data": ["id": .string(face), "type": "media_input"]]], "item_medias": [],
        ]

        static func tools() throws -> [JSONValue] {
            Provider.fullSet
                + (try [
                    "ai_influencer_get_options", "ai_influencer_list_presets", "ai_influencer_prepare",
                    "ai_influencer_generate", "assets_picker_list", "jobs_wait",
                ].map(CatalogSnapshot.tool))
        }

        static func reply(_ name: String, _ arguments: JSONValue) -> JSONValue {
            switch name {
            case "ai_influencer_get_options":
                return [
                    "tiers": ["cats"],
                    "groups": [
                        [
                            "id": "fur", "label": "Fur", "max": 1,
                            "options": [["id": "ginger", "label": "Ginger", "slot": .null, "tiers": ["cats"]]],
                        ],
                        ["id": "hair", "label": "Hair", "max": 2, "options": []],
                    ],
                ]
            case "ai_influencer_list_presets":
                return [
                    "total": 1, "cursor": .null,
                    "items": [
                        [
                            "id": .string(face), "name": "Chef", "priority": 1,
                            "preview": ["url": "https://cdn.example.com/p.webp"],
                            "sheet": ["url": "https://cdn.example.com/s.png"],
                            "recreate": [
                                "job_set_type": "ai_influencer_sheet",
                                "params": [
                                    "tier": "cats", "selection": ["fur": ["ginger"]], "brief": "a chef", "seed": 12,
                                    "medias": [],
                                ],
                            ],
                            "recreate_unavailable_reason": .null,
                        ]
                    ],
                ]
            case "ai_influencer_prepare":
                return ["params": params, "credits": .number(23.2), "free_gens_remaining": 1, "submitted": false]
            case "ai_influencer_generate":
                return [
                    "submitted": true, "job_id": .string(jobs[0]), "job_ids": .array(jobs.map(JSONValue.string)),
                    "credits": .number(23.2), "use_free_gens": false, "results": [],
                ]
            case "jobs_wait":
                return [
                    "jobs": [
                        [
                            "index": 0, "job_id": .string(jobs[0]), "status": "completed", "type": "image",
                            "result_url": "https://cdn.example.com/sheet.png",
                        ]
                    ],
                    "poll_after_seconds": 3,
                ]
            case "generate_video":
                return ["results": [["id": "job-1"]]]
            case "job_status":
                return ["generation": ["status": "in_progress"]]
            case "assets_picker_list":
                return [
                    "items": [
                        [
                            "id": .string(jobs[1]), "kind": "image", "url": "https://cdn.example.com/other.png",
                            "createdAt": 1_760_000_000,
                        ]
                    ],
                    "next_cursor": .null,
                ]
            default:
                return [:]
            }
        }

        @Test func traitsAndPresetsAreReadInTheAppsTerms() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)

            let groups = try await provider.characterTraits(for: .cats)
            let presets = try await provider.characterPresets(after: nil)

            // A group the tier has no option in isn't shown.
            #expect(
                groups == [
                    CharacterTraitGroup(
                        id: "fur", title: "Fur", maxPicks: 1, traits: [CharacterTrait(id: "ginger", title: "Ginger")])
                ])
            #expect(
                presets.items.first?.settings
                    == CharacterPresetSettings(tier: .cats, traits: ["fur": ["ginger"]], brief: "a chef", seed: 12))
            #expect(presets.nextCursor == nil)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func theLiveAnswersReadInTheAppsTerms() async throws {
            let answers = try [
                "ai_influencer_get_options", "ai_influencer_list_presets", "ai_influencer_prepare",
                "assets_picker_list_influencer",
            ].map(CatalogSnapshot.liveAnswer)
            let byTool = Dictionary(answers.map { ($0.tool, $0.answer) }, uniquingKeysWith: { first, _ in first })
            let (provider, stub) = Provider.provider(tools: try Self.tools()) { name, _ in byTool[name] ?? [:] }

            let groups = try await provider.characterTraits(for: .normal)
            let presets = try await provider.characterPresets(after: nil)
            let quote = try await provider.quoteCharacters(CharacterDesign(tier: nil, count: 1))
            let sheets = try await provider.characterSheets(after: nil)

            #expect(groups.first { $0.id == "freak_face" }?.maxPicks == 4)
            #expect(groups.first?.traits.first == CharacterTrait(id: "female", title: "Female"))
            #expect(presets.items.first?.settings?.tier == .freak)
            #expect(presets.items.first?.settings?.seed == 427_752)
            #expect(presets.items.first?.previewURL != nil)
            // Three presets where thirty were asked for: the last page.
            #expect(presets.nextCursor == nil)
            #expect(quote.credits == 1.125)
            #expect(quote.cost == .credits(1.125, isEstimate: false))
            #expect(sheets.items.isEmpty)
            #expect(sheets.nextCursor == nil)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func theQuoteIsGeneratedUnchangedWithItsPriceAsTheCap() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)
            let design = CharacterDesign(
                tier: .cats, traits: ["fur": ["ginger"]], brief: "a sleepy chef", count: 2,
                face: RemoteAsset(url: URL(string: "https://upload.example.com/f.jpg")!, id: Self.face),
                randomize: false)

            let quote = try await provider.quoteCharacters(design)
            let jobs = try await provider.generateCharacters(quote)

            #expect(quote.credits == 23.2)
            #expect(quote.cost == .credits(Decimal(string: "23.2")!, isEstimate: false))
            #expect(jobs.map(\.requestID) == Self.jobs)
            let calls = Provider.calls(stub)
            #expect(calls.map { $0["name"] } == ["ai_influencer_prepare", "ai_influencer_generate"])
            #expect(calls[0]["arguments"]?["tier"] == "cats")
            #expect(calls[0]["arguments"]?["batch_size"] == 2)
            #expect(calls[1]["arguments"] == ["params": Self.params, "max_credits": .number(23.2)])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func aSubmitThatMayHaveReachedTheServerIsNeverRetried() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools()) { name, arguments in
                name == "ai_influencer_generate" ? ["submitted": true] : Self.reply(name, arguments)
            }
            let quote = CharacterQuote(credits: 10, count: 1, request: try JSONEncoder().encode(Self.params))

            await #expect(throws: ProviderError.outcomeUnknown) { try await provider.generateCharacters(quote) }
            #expect(Provider.calls(stub).filter { $0["name"] == "ai_influencer_generate" }.count == 1)
        }

        /// `ai_influencer_generate` charges: a failure it reports may come after the charge, so it isn't retried.
        @Test(arguments: [
            JSONValue.object(["result": ["isError": true, "content": [["type": "text", "text": "Internal failure"]]]]),
            ["error": ["code": -32603, "message": "Internal failure"]],
        ])
        func aFailedSubmitMayHaveBeenCharged(payload: JSONValue) async throws {
            let stub = Provider.answering(
                "ai_influencer_generate", with: payload, tools: try Self.tools(), call: Self.reply)
            let provider = makeProvider(stub.session())
            let quote = CharacterQuote(credits: 10, count: 1, request: try JSONEncoder().encode(Self.params))

            await #expect(throws: ProviderError.outcomeUnknown) { try await provider.generateCharacters(quote) }
        }

        @Test func aRefusedSubmitGivesItsReason() async throws {
            let (provider, _) = Provider.provider(tools: try Self.tools()) { name, arguments in
                name == "ai_influencer_generate"
                    ? ["submitted": false, "credits": 30, "error": "Price is above max_credits"]
                    : Self.reply(name, arguments)
            }
            let quote = CharacterQuote(credits: 10, count: 1, request: try JSONEncoder().encode(Self.params))

            await #expect(throws: ProviderError.validation(field: nil, message: "Price is above max_credits")) {
                try await provider.generateCharacters(quote)
            }
        }

        @Test func statusesComeFromJobsWaitThenJobStatusForTheRest() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)

            let statuses = try await provider.characterSheetStatuses(Self.jobs.map { RemoteJob(requestID: $0) })

            #expect(statuses[Self.jobs[0]] == .completed([URL(string: "https://cdn.example.com/sheet.png")!]))
            #expect(statuses[Self.jobs[1]] == .pending)
            #expect(Provider.calls(stub).map { $0["name"] } == ["jobs_wait", "job_status"])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func theAccountListIsReadFromTheInfluencerSource() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)

            let page = try await provider.characterSheets(after: nil)
            #expect(page.items.map(\.id) == [Self.jobs[1]])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func aSheetIsSentToAVideoJobByItsJobID() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)
            let sheet = ServerMedia(
                id: Self.jobs[0], url: URL(string: "https://cdn.example.com/sheet.png")!, owner: "user_1")

            let asset = try #require(try await provider.serverAsset(sheet))
            _ = try await provider.submit(
                Provider.spec(.motionTransfer), inputs: RemoteInputs(video: Provider.inputs.video, images: [asset]),
                idempotencyKey: UUID())

            let generate = Provider.calls(stub).first { $0["name"] == "generate_video" }
            #expect(
                generate?["arguments"]?["params"]?["medias"]
                    == [
                        ["role": "video_references", "value": "video-1"],
                        ["role": "image_references", "value": .string(Self.jobs[0])],
                    ])
        }
    }
}
