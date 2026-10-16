import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

private let submitted = """
    {"status": "queued", "request_id": "req-7",
     "status_url": "https://api.higgsfield.ai/requests/req-7/status",
     "cancel_url": "https://api.higgsfield.ai/requests/req-7/cancel"}
    """

private let soul = "higgsfield-ai/soul/v2/standard"
private let grok = "xai/grok-imagine-image-2.0"
private let qwen = "alibaba/qwen-image-3/edit"
private let input = RemoteAsset(url: URL(string: "https://cdn.example.com/in.png")!, id: "media-1")

extension Network {
    /// Reference images with an API key (issue #42): the curated models, their REST bodies, `/estimate` and the
    /// list price when it can't answer.
    @Suite struct APIImages {
        @Test func theCuratedModelsAreTheDocumentedEndpoints() async throws {
            let models = try await StubServer().makeAPIProvider().imageModels()
            #expect(models.map(\.id) == [soul, grok, qwen])
            #expect(models.map(\.variantCounts) == [[1, 4], [1], [1]])
            #expect(models.map(\.input) == [.none, .optional, .required])
        }

        @Test func estimateQuotesTheExactBody() async throws {
            let server = StubServer()
            server.on("POST", "/estimate/\(soul)", StubResponse(body: #"{"usd": "0.0128"}"#))
            let request = ImageRequest(model: soul, prompt: "a knight", aspectRatio: "9:16", count: 4)

            let cost = try await server.makeAPIProvider().imageEstimate(request)

            #expect(cost == .usd(Decimal(string: "0.0128")!, isEstimate: false))
            #expect(server.requests.first?.bodyText == #"{"aspect_ratio":"9:16","batch_size":4,"prompt":"a knight"}"#)
        }

        @Test func anUnreachableEstimateFallsBackToTheListPrice() async throws {
            let server = StubServer()
            server.on("POST", "/estimate/\(soul)", StubResponse(status: 500, body: "{}"))
            let request = ImageRequest(model: soul, prompt: "a knight", aspectRatio: "1:1", count: 4)

            let cost = try await server.makeAPIProvider().imageEstimate(request)

            #expect(cost == .usd(Decimal(string: "0.0128")!, isEstimate: true))
        }

        @Test func aRefusedEstimateIsNotHidden() async throws {
            let server = StubServer()
            server.on(
                "POST", "/estimate/\(soul)", StubResponse(status: 401, body: #"{"detail": "Invalid credentials"}"#))
            let request = ImageRequest(model: soul, prompt: "a knight", aspectRatio: "1:1", count: 1)
            await #expect(throws: ProviderError.unauthorized) {
                try await server.makeAPIProvider().imageEstimate(request)
            }
        }

        @Test func editSendsTheInputAndPollsTheImages() async throws {
            let server = StubServer()
            server.on("POST", "/\(grok)", StubResponse(body: submitted))
            server.on(
                "GET", "/requests/req-7/status",
                StubResponse(body: #"{"status": "completed", "images": [{"url": "https://cdn.example.com/1.png"}]}"#))
            let provider = server.makeAPIProvider()
            let request = ImageRequest(
                model: grok, prompt: "add a cape", aspectRatio: "3:4", count: 1, inputImages: [input])

            let jobs = try await provider.submitImages(request, idempotencyKey: UUID())
            let status = try await provider.imageStatus(try #require(jobs.first))

            #expect(jobs.map(\.requestID) == ["req-7"])
            #expect(status == .completed([URL(string: "https://cdn.example.com/1.png")!]))
            #expect(
                server.requests.first?.bodyText
                    == #"{"aspect_ratio":"3:4","image_urls":["https://cdn.example.com/in.png"],"prompt":"add a cape"}"#)
            #expect(server.requests.first?.header("Idempotency-Key") != nil)
        }

        @Test(arguments: [
            (
                ImageRequest(model: qwen, prompt: "add a cape", aspectRatio: "1:1", count: 1),
                ProviderError.validation(field: "image_urls", message: "Qwen Image 3 Edit needs an image to edit.")
            ),
            (
                ImageRequest(model: soul, prompt: "a knight", aspectRatio: "1:1", count: 2),
                .validation(field: "batch_size", message: "Soul 2 can't make that many images.")
            ),
            (
                ImageRequest(model: soul, prompt: "  ", aspectRatio: "1:1", count: 1),
                .validation(field: "prompt", message: "Describe the image to make.")
            ),
            (
                ImageRequest(model: "bytedance/seedance-2.5/text-to-video", prompt: "x", aspectRatio: "1:1", count: 1),
                .validation(field: "model", message: "This image model can't run with an API key.")
            ),
        ])
        func anInvalidRequestIsRefusedBeforeSending(request: ImageRequest, error: ProviderError) async {
            let server = StubServer()
            await #expect(throws: error) {
                try await server.makeAPIProvider().submitImages(request, idempotencyKey: UUID())
            }
            #expect(server.requests.isEmpty)
        }
    }

    /// Reference images on the account, with the tool definitions and the image list of the catalog snapshot of
    /// 2026-10-15.
    @Suite struct AccountImages {
        static func tools() throws -> [JSONValue] {
            Provider.fullSet.filter { $0["name"] != "generate_image" }
                + [try CatalogSnapshot.tool("generate_image"), try CatalogSnapshot.tool("models_explore")]
        }
        static let request = ImageRequest(
            model: "nano_banana_pro", prompt: "a knight", aspectRatio: "9:16", count: 2, inputImages: [input])
        static let jobIDs = ["3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", "7d2e9b41-0c3a-4f6e-8b12-5a9c0d1e2f34"]

        /// The snapshot's image list, and each of its items for `get`.
        static func reply(_ name: String, _ arguments: JSONValue) -> JSONValue {
            let list = (try? CatalogSnapshot.value(CatalogSnapshot.imageList)) ?? [:]
            switch name {
            case "models_explore" where arguments["action"] == "get":
                return list["items"]?.arrayValue?.first { $0["id"] == arguments["model_id"] } ?? [:]
            case "models_explore":
                return arguments["after"] == nil ? list : ["items": [], "has_more": false]
            case "generate_image" where arguments["params"]?["get_cost"] == true:
                return ["cost": ["credits": 3, "credits_exact": .number(2.5)]]
            case "generate_image":
                return ["results": [["id": .string(jobIDs[0])], ["id": .string(jobIDs[1])]], "request_id": "req-1"]
            case "job_status":
                return ["generation": ["status": "completed", "results": ["rawUrl": "https://cdn.example.com/1.png"]]]
            default:
                return [:]
            }
        }

        @Test func imagesRunWithEachModelsOwnFramesAndImageRole() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)

            let models = try await provider.imageModels()
            let cost = try await provider.imageEstimate(Self.request)
            let jobs = try await provider.submitImages(Self.request, idempotencyKey: UUID())
            let status = try await provider.imageStatus(try #require(jobs.first))

            #expect(models.map(\.id) == ["soul_2", "gpt_image_2", "soul_cast", "nano_banana_pro"])
            #expect(models.first?.variantCounts == [1, 2, 3, 4])
            #expect(models.first?.aspectRatios == ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"])
            #expect(models.map(\.input) == [.optional, .optional, .none, .optional])
            // get_cost prices one image: 2.5 credits times the request's 2.
            #expect(cost == .credits(5, isEstimate: false))
            #expect(jobs.map(\.requestID) == Self.jobIDs)
            #expect(status == .completed([URL(string: "https://cdn.example.com/1.png")!]))
            let generate = Provider.calls(stub).last { $0["name"] == "generate_image" }
            #expect(
                generate?["arguments"]?["params"]?["medias"] == [["role": "image_references", "value": "media-1"]])
            #expect(generate?["arguments"]?["params"]?["use_unlim"] == false)
            #expect(try Provider.schemaViolations(stub).isEmpty)
            await #expect(throws: HiggsfieldMCPProvider.notCancellable) { try await provider.cancelImages(jobs[0]) }
        }

        @Test func anImageGoesInUnderTheModelsRoleAndWithinItsCount() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)
            var soul = Self.request
            soul.model = "soul_2"

            _ = try await provider.submitImages(soul, idempotencyKey: UUID())
            let generate = Provider.calls(stub).last { $0["name"] == "generate_image" }
            #expect(generate?["arguments"]?["params"]?["medias"] == [["role": "image", "value": "media-1"]])

            soul.inputImages = [input, input]
            await #expect(
                throws: ProviderError.validation(field: nil, message: "This model takes at most 1 image.")
            ) { try await provider.submitImages(soul, idempotencyKey: UUID()) }
            var cast = Self.request
            cast.model = "soul_cast"
            await #expect(throws: ProviderError.validation(field: nil, message: "This model doesn't take an image.")) {
                try await provider.submitImages(cast, idempotencyKey: UUID())
            }
            #expect(Provider.calls(stub).filter { $0["name"] == "generate_image" }.count == 1)
        }

        @Test func eachFamilyGetsATurnAndATwiceListedModelShowsOnce() {
            let listed = [
                "soul_2", "soul_cinematic", "gpt_image_2", "soul_cast", "soul_location", "soul_v2", "nano_banana",
                "grok_image", "grok_image_2_0", "nano_banana_pro",
            ].map { AccountImageModel(id: $0, name: $0 == "soul_v2" ? "soul_2" : $0, aspectRatios: ["1:1"]) }
            #expect(
                HiggsfieldProviders.AccountImages.models(listed).map(\.id)
                    == ["soul_2", "soul_cinematic", "gpt_image_2", "nano_banana", "grok_image", "grok_image_2_0"])
        }

        @Test func anAccountListingNoneOfTheCuratedModelsOffersItsFirst() {
            let listed = (1...8).map {
                AccountImageModel(id: "model_\($0)", name: "Model \($0)", aspectRatios: ["1:1"])
            }
            let animation = AccountImageModel(id: "soul_sprite", name: "Sprite")
            #expect(
                HiggsfieldProviders.AccountImages.models([animation] + listed).map(\.id)
                    == (1...6).map { "model_\($0)" })
        }
    }
}
