import Foundation
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `models_explore` `get` answers in shapes other than the live one (`CatalogSnapshot`), still read tolerantly.
enum ModelLimitsFixture {
    static let seedance: JSONValue = [
        "id": "seedance_2_5",
        "parameters": [
            "duration": ["type": "integer", "minimum": 4, "maximum": 30, "default": 5],
            "resolution": ["enum": ["480p", "720p", "1080p"]],
        ],
        "medias": [
            ["role": "video_references", "min": 0, "max": 3],
            ["role": "image_references", "min": 0, "max": 9],
        ],
        "supports_unlim": false,
    ]
}

@Suite struct ModelLimitsDecoding {
    /// Seedance 2.5 states its duration, 4–30 s; no answer counts the reference images, and Kling 3.0 Motion
    /// Control and Genjutsu state no duration, so those bounds keep the app's constants.
    @Test func theSnapshotsAnswersAreRead() throws {
        #expect(
            ModelLimits(answer: try CatalogSnapshot.value(CatalogSnapshot.seedance))
                == ModelLimits(minDuration: 4, maxDuration: 30))
        #expect(ModelLimits(answer: try CatalogSnapshot.value(CatalogSnapshot.kling)) == ModelLimits())
        #expect(ModelLimits(answer: try CatalogSnapshot.value(CatalogSnapshot.motionControl)) == ModelLimits())
    }

    @Test func anObjectOfParametersIsReadToo() {
        #expect(
            ModelLimits(answer: ModelLimitsFixture.seedance)
                == ModelLimits(minDuration: 4, maxDuration: 30, minImages: 0, maxImages: 9))
    }

    @Test func otherShapesAreReadToo() {
        let nested: JSONValue = [
            "model": [
                "params": ["properties": ["duration": ["min": 3, "max": 12]]],
                "media": [["roles": ["image_references", "image"], "min_count": 1, "max_count": 1]],
            ]
        ]
        #expect(ModelLimits(answer: nested) == ModelLimits(minDuration: 3, maxDuration: 12, minImages: 1, maxImages: 1))

        let listed: JSONValue = [
            "data": [
                "parameters": [["name": "prompt"], ["name": "duration", "enum": [5, 6, 7, 8]]],
                "medias": [["type": "image", "maxItems": 4]],
            ]
        ]
        #expect(ModelLimits(answer: listed) == ModelLimits(minDuration: 5, maxDuration: 8, maxImages: 4))
    }

    @Test func anEnumWithGapsIsNoRange() {
        let answer: JSONValue = ["parameters": ["duration": ["enum": [5, 10]]]]
        #expect(ModelLimits(answer: answer) == ModelLimits())
    }

    @Test func framesAreNotReferenceImages() {
        let answer: JSONValue = ["medias": [["role": "start_image", "max": 1], ["role": "end_image", "max": 1]]]
        #expect(ModelLimits(answer: answer) == ModelLimits())
    }

    static let junk: [JSONValue] = [
        .null, "seedance_2_5", 42, [], [:], ["parameters": "duration"], ["parameters": ["duration": "4-30"]],
        ["parameters": ["duration": ["minimum": "4", "maximum": .null]]],
        ["parameters": ["duration": ["enum": ["5", "10"]]]],
        ["parameters": ["duration": ["enum": [.number(4.5), .number(5.5)]]]],
        ["parameters": ["duration": ["enum": [0, .number(1e300)]]]], ["medias": "image_references"],
        ["medias": [["role": "image_references", "max": -1, "min": .number(2.5)]]],
        ["medias": [["role": 7, "max": 3]]],
        ["model": "seedance_2_5"],
    ]

    @Test(arguments: junk)
    func junkReadsAsNothing(answer: JSONValue) {
        #expect(ModelLimits(answer: answer) == ModelLimits())
    }
}

extension Network {
    @Suite struct ModelLimitsReads {
        static let explore = tool("models_explore", "Explore models", ["action", "type", "model_id", "after", "limit"])
        static let models: [VideoRequest.Model] = [.motionControl, .replaceObject, .seedance25, .klingMotionControl]

        @Test func withoutModelsExploreThereIsNoAnswer() async throws {
            let (account, stub) = Account.account(tools: Account.fullSet)
            #expect(try await account.modelLimits(of: Self.models) == nil)
            #expect(Account.calls(stub).isEmpty)
        }

        @Test func getsEachModel() async throws {
            let seedance = try CatalogSnapshot.value(CatalogSnapshot.seedance)
            let kling = try CatalogSnapshot.value(CatalogSnapshot.kling)
            let (account, stub) = Account.account(tools: Account.fullSet + [Self.explore]) { _, arguments in
                switch arguments["model_id"]?.stringValue {
                case "seedance_2_5": seedance
                case "kling3_0_motion_control": kling
                default: ["id": arguments["model_id"] ?? .null]
                }
            }

            let limits = try #require(try await account.modelLimits(of: Self.models))

            #expect(limits[.seedance25] == ModelLimits(minDuration: 4, maxDuration: 30))
            #expect(limits[.klingMotionControl] == ModelLimits())
            #expect(Set(limits.keys) == Set(Self.models))
            let calls = Account.calls(stub).filter { $0["name"] == "models_explore" }.compactMap { $0["arguments"] }
            #expect(calls.count == Self.models.count)
            #expect(calls.compactMap { $0["model_id"]?.stringValue } == Self.models.map(\.rawValue))
            #expect(calls.allSatisfy { $0["action"] == "get" })
        }
    }
}
