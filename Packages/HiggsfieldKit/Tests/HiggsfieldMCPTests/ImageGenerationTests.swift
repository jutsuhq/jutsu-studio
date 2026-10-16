import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `generate_image` and `models_explore {type: "image"}` (issue #42), against the tool schemas and the image list of
/// the catalog snapshot of 2026-10-15.
extension Network {
    @Suite struct ImageGenerations {
        static func tools() throws -> [JSONValue] {
            Account.fullSet.filter { $0["name"] != "generate_image" }
                + [try CatalogSnapshot.tool("generate_image"), try CatalogSnapshot.tool("models_explore")]
        }

        static let request = AccountImageRequest(
            model: "soul_2", prompt: "a knight in silver armor", aspectRatio: "9:16", count: 4, imageIDs: ["media-1"],
            imageRole: "image")

        @Test func generateSendsTheParamsTheSchemaTakesAndReadsEveryJob() async throws {
            let (account, stub) = Account.account(tools: try Self.tools()) { _, arguments in
                arguments["params"]?["get_cost"] == true
                    ? ["cost": ["credits": 8, "credits_exact": .number(7.5)]]
                    : ["results": [["id": "job-1"], ["id": "job-2"]], "request_id": "req-1", "cost": ["credits": 8]]
            }

            #expect(try await account.cost(of: Self.request) == 7.5)
            let jobs = try await account.generateImages(Self.request)

            #expect(jobs.map(\.id) == ["job-1", "job-2"])
            #expect(jobs.map(\.credits) == [8, nil])
            let params: JSONValue = [
                "model": "soul_2", "prompt": "a knight in silver armor", "aspect_ratio": "9:16", "count": 4,
                "medias": [["role": "image", "value": "media-1"]], "use_unlim": false,
            ]
            var quoted = params
            if case .object(var object) = quoted {
                object["get_cost"] = true
                quoted = .object(object)
            }
            #expect(
                Account.calls(stub).map { $0["arguments"] } == [["params": quoted], ["params": params]])
            #expect(Account.calls(stub).map { $0["name"] } == ["generate_image", "generate_image"])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func anAnswerWithoutAJobIsNotARefusal() async throws {
            let (account, _) = Account.account(tools: try Self.tools()) { _, _ in ["ok": true] }
            await #expect(throws: HiggsfieldError.server(status: 200)) {
                try await account.generateImages(Self.request)
            }
        }

        @Test func aMissingToolIsReportedBeforeAnyCall() async throws {
            let tools = Account.fullSet.filter { $0["name"] != "generate_image" }
            let (account, stub) = Account.account(tools: tools)
            await #expect(throws: HiggsfieldError.toolUnavailable("generate_image")) {
                try await account.checkImageTool()
            }
            #expect(Account.calls(stub).isEmpty)
        }

        @Test func imageModelsAreReadFromTheSnapshotList() async throws {
            let (account, stub) = Account.account(tools: try Self.tools()) { _, arguments in
                arguments["after"] == nil
                    ? (try? CatalogSnapshot.value(CatalogSnapshot.imageList)) ?? [:]
                    : ["items": [["id": "flux_2", "name": "FLUX.2"], ["id": "soul_2"]], "has_more": false]
            }

            let models = try #require(try await account.imageModels())

            #expect(models.map(\.id) == ["soul_2", "gpt_image_2", "soul_cast", "nano_banana_pro", "flux_2"])
            #expect(
                models.first
                    == AccountImageModel(
                        id: "soul_2", name: "Higgsfield Soul 2.0",
                        aspectRatios: ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"], imageRole: "image",
                        maxImages: 1))
            #expect(models.map(\.imageRole) == ["image", "image", nil, "image_references", nil])
            #expect(models[3].maxImages == nil)
            #expect(
                Account.calls(stub).compactMap { $0["arguments"] } == [
                    ["action": "list", "type": "image", "limit": 100],
                    ["action": "list", "type": "image", "limit": 100, "after": "20"],
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func oneModelIsDescribedByGet() async throws {
            let (account, stub) = Account.account(tools: try Self.tools()) { _, _ in
                let list = (try? CatalogSnapshot.value(CatalogSnapshot.imageList)) ?? [:]
                return list["items"]?.arrayValue?.last ?? [:]
            }

            let model = try await account.imageModel(id: "nano_banana_pro")

            #expect(model?.imageRole == "image_references")
            #expect(Account.calls(stub).first?["arguments"] == ["action": "get", "model_id": "nano_banana_pro"])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func withoutModelsExploreThereIsNoList() async throws {
            let (account, _) = Account.account()
            #expect(try await account.imageModels() == nil)
            #expect(try await account.imageModel(id: "soul_2") == nil)
        }

        @Test(arguments: [
            (["status": "queued"] as JSONValue, ImageStatus.queued),
            (["status": "in_progress"] as JSONValue, .inProgress),
            (["status": "nsfw"] as JSONValue, .rejected(.explicitContent)),
            (["status": "failed", "error": "bad prompt"] as JSONValue, .failed(message: "bad prompt")),
            (
                ["status": "completed", "results": ["rawUrl": "https://cdn.example.com/a.png"]] as JSONValue,
                .completed(imageURLs: [URL(string: "https://cdn.example.com/a.png")!])
            ),
            (
                ["status": "completed", "results": ["rawUrl": "http://cdn.example.com/a.png"]] as JSONValue,
                .failed(message: "Completed without an image URL.")
            ),
        ])
        func imageStatusReadsTheResult(generation: JSONValue, expected: ImageStatus) async throws {
            let (account, _) = Account.account { _, _ in ["generation": generation] }
            #expect(try await account.imageStatus(of: "job-1") == expected)
        }
    }
}
