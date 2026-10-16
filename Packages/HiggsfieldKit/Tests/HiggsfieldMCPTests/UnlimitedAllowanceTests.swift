import Foundation
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `models_explore` `list` pages: model items carrying `supports_unlim`, and a top-level `unlim` block for the
/// account. `CatalogSnapshot` has the live shape; anything else must read as "no allowance".
enum UnlimitedFixture {
    static let page: JSONValue = [
        "models": [
            ["id": "hf_mult_motion_control", "supports_unlim": true],
            ["id": "seedance_2_5", "supports_unlim": false],
            ["id": "kling3_0_motion_control"],
        ],
        "unlim": ["available": true],
    ]

    /// The snapshot's `unlim` block, as it would read with an unmetered allowance.
    static let unmetered: JSONValue = ["available": true, "expires_at": "2026-10-18T00:00:00Z", "remaining": .null]
}

@Suite struct UnlimitedAllowanceDecoding {
    /// The account of the snapshot had no allowance; Seedance 2.0 is the page's one model that takes it.
    @Test func theSnapshotsListPageIsRead() throws {
        let page = try CatalogSnapshot.value(CatalogSnapshot.videoList)
        #expect(
            UnlimitedAllowance(pages: [page])
                == UnlimitedAllowance(isAvailable: false, supportedModels: ["seedance_2_0"]))

        let unmetered = try CatalogSnapshot.value(
            CatalogSnapshot.videoList, changing: ["unlim": UnlimitedFixture.unmetered])
        #expect(UnlimitedAllowance(pages: [unmetered]).isAvailable)
    }

    /// `get` answers carry the same keys: Kling 3.0 Motion Control takes the allowance, Seedance 2.5 doesn't.
    @Test func theSnapshotsModelsAreReadAsItems() throws {
        let page: JSONValue = [
            "items": [
                try CatalogSnapshot.value(CatalogSnapshot.kling), try CatalogSnapshot.value(CatalogSnapshot.seedance),
            ],
            "unlim": UnlimitedFixture.unmetered,
        ]
        let allowance = UnlimitedAllowance(pages: [page])
        #expect(allowance.covers(.klingMotionControl))
        #expect(!allowance.covers(.seedance25))
    }

    @Test func bothSignalsCoverOnlyTheSupportedModel() {
        let allowance = UnlimitedAllowance(pages: [UnlimitedFixture.page])
        #expect(allowance.isAvailable)
        #expect(allowance.supportedModels == ["hf_mult_motion_control"])
        #expect(allowance.covers(.motionControl))
        #expect(!allowance.covers(.seedance25))
        #expect(!allowance.covers(.klingMotionControl))
    }

    @Test func withoutTheFieldsNothingIsCovered() {
        let page: JSONValue = ["models": [["id": "hf_mult_motion_control"]]]
        let allowance = UnlimitedAllowance(pages: [page])
        #expect(allowance == .none)
        #expect(!allowance.covers(.motionControl))
    }

    @Test func supportWithoutTheAccountsAllowanceCoversNothing() {
        let page: JSONValue = ["models": [["id": "hf_mult_motion_control", "supports_unlim": true]]]
        let allowance = UnlimitedAllowance(pages: [page])
        #expect(allowance.supportedModels == ["hf_mult_motion_control"])
        #expect(!allowance.covers(.motionControl))
    }

    @Test func anAllowanceWithoutSupportCoversNothing() {
        let page: JSONValue = ["models": [["id": "hf_mult_motion_control"]], "unlim": true]
        #expect(!UnlimitedAllowance(pages: [page]).covers(.motionControl))
    }

    static let blocks: [(block: JSONValue, available: Bool)] = [
        (true, true),
        (false, false),
        (["available": true], true),
        (["can_use": true, "remaining": 3], true),
        (["available": true, "remaining": 0], false),
        (["enabled": false], false),
        (["available": true, "active": false], false),
        (["remaining": 12], true),
        (["available": true, "expires_at": .null, "remaining": .null], true),
        (["available": false, "expires_at": .null, "remaining": .null], false),
        (["remaining": .null], false),
        (["plan": "ultra"], false),
        (["available": "yes"], false),
        ("true", false),
        (.null, false),
    ]

    @Test(arguments: blocks)
    func theUnlimBlockSaysYesOnlyInAKnownShape(block: JSONValue, available: Bool) {
        #expect(UnlimitedAllowance.isAvailable(block) == available)
    }

    @Test func itemsAndIDsAreReadUnderTheirOtherNames() {
        let pages: [JSONValue] = [
            ["items": [["model_id": "seedance_2_5", "supports_unlim": true]], "unlim": ["available": true]],
            ["data": [["model": "kling3_0_motion_control", "supports_unlim": true]]],
        ]
        let allowance = UnlimitedAllowance(pages: pages)
        #expect(allowance.covers(.seedance25))
        #expect(allowance.covers(.klingMotionControl))
    }

    @Test func aSupportFlagThatIsntABoolDoesntCount() {
        let page: JSONValue = [
            "models": [["id": "seedance_2_5", "supports_unlim": "true"]], "unlim": ["available": true],
        ]
        #expect(!UnlimitedAllowance(pages: [page]).covers(.seedance25))
    }

    @Test func useUnlimIsFalseUnlessTheRequestAsksForIt() {
        var request = VideoRequest(model: .motionControl, media: [])
        #expect(request.arguments()["params"]?["use_unlim"] == false)
        request.usesUnlimited = true
        #expect(request.arguments()["params"]?["use_unlim"] == true)
        #expect(request.arguments(getCost: true)["params"]?["use_unlim"] == true)
    }
}

extension Network {
    @Suite struct Unlimited {
        static let explore = tool("models_explore", "Explore models", ["action", "type", "model_id", "after", "limit"])
        static let generate = tool("generate_video", "Generate one direct video request", ["params", "context"])
        /// The models the app runs on an account, as it passes them.
        static let models: Set<VideoRequest.Model> = [.motionControl, .replaceObject, .seedance25, .klingMotionControl]

        static func listCalls(_ stub: StubServer) -> [JSONValue] {
            Account.calls(stub).filter { $0["name"] == "models_explore" }.compactMap { $0["arguments"] }
        }

        @Test func withoutModelsExploreThereIsNoAnswer() async throws {
            let (account, stub) = Account.account(tools: [Self.generate])
            #expect(try await account.unlimitedAllowance(for: Self.models) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        /// The snapshot's first page (with an allowance), then a page with the app's models, as `get` gave them.
        @Test func readsTheVideoListUntilEveryModelWasSeen() async throws {
            let first = try CatalogSnapshot.value(
                CatalogSnapshot.videoList, changing: ["unlim": UnlimitedFixture.unmetered])
            let second: JSONValue = [
                "items": [
                    try CatalogSnapshot.value(CatalogSnapshot.kling),
                    try CatalogSnapshot.value(CatalogSnapshot.seedance),
                    try CatalogSnapshot.value(CatalogSnapshot.motionControl), ["id": "hf_mult_replace_object"],
                ],
                "has_more": true, "next_page_token": "40", "unlim": UnlimitedFixture.unmetered,
            ]
            let (account, stub) = Account.account(tools: [Self.explore]) { _, arguments in
                arguments["after"] == nil ? first : second
            }

            let allowance = try #require(try await account.unlimitedAllowance(for: Self.models))

            #expect(allowance.covers(.klingMotionControl))
            #expect(!allowance.covers(.seedance25) && !allowance.covers(.motionControl))
            let calls = Self.listCalls(stub)
            #expect(calls.count == 2)  // every model seen on page 2, so page 3 isn't read
            #expect(calls.first == ["action": "list", "type": "video", "limit": 100])
            #expect(calls.last == ["action": "list", "type": "video", "limit": 100, "after": "20"])
        }

        /// The snapshot's page: no allowance now, so the next page isn't read.
        @Test func noAllowanceOnTheFirstPageEndsTheRead() async throws {
            let page = try CatalogSnapshot.value(CatalogSnapshot.videoList)
            let (account, stub) = Account.account(tools: [Self.explore]) { _, _ in page }
            #expect(
                try await account.unlimitedAllowance(for: Self.models)
                    == UnlimitedAllowance(isAvailable: false, supportedModels: ["seedance_2_0"]))
            #expect(Self.listCalls(stub).count == 1)
        }

        @Test func aLastPageEndsTheRead() async throws {
            let page = try CatalogSnapshot.value(
                CatalogSnapshot.videoList, changing: ["unlim": UnlimitedFixture.unmetered, "has_more": false])
            let (account, stub) = Account.account(tools: [Self.explore]) { _, _ in page }
            #expect(try await account.unlimitedAllowance(for: Self.models)?.isAvailable == true)
            #expect(Self.listCalls(stub).count == 1)
        }

        /// `generate_video`'s `outputSchema` sends `cost` only for `get_cost`; one in a submit's answer is still read.
        @Test func generateReadsTheCreditsTheAnswerNames() async throws {
            let (account, _) = Account.account { _, _ in
                ["results": [["id": "job-1"]], "cost": ["credits_exact": .number(12.5), "credits": 13]]
            }
            #expect(try await account.generate(Account.request).credits == 12.5)
        }

        @Test func generateWithoutACostHasNoCredits() async throws {
            let (account, _) = Account.account { _, _ in ["results": [["id": "job-1"]]] }
            #expect(try await account.generate(Account.request).credits == nil)
        }
    }
}
