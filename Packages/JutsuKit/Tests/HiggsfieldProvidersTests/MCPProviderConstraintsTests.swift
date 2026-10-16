import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

@Suite struct AccountModelConstraintsTests {
    static let seedance45 = ModelConstraintTable(entries: [
        .init(model: .seedance25, mode: .motionTransfer, constraints: ModelConstraints(maxDuration: 45))
    ])

    /// Seedance on a 40 s selection.
    static let spec: JobSpec = {
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/in.mov"), duration: 60, pixelSize: PixelSize(width: 1280, height: 720),
            range: 0...40)
        return JobSpec(mode: .motionTransfer, model: .seedance25, source: source, resolution: .p720)
    }()

    @Test func eachGenerateModelLimitsItsJob() {
        let table = AccountModel.constraints(from: [
            .motionControl: ModelLimits(maxImages: 4), .replaceObject: ModelLimits(minImages: 2),
            .seedance25: ModelLimits(minDuration: 5, maxDuration: 45),
        ])
        #expect(
            table.entries == [
                .init(model: .genjutsu, mode: .motionTransfer, constraints: ModelConstraints(maxReferenceImages: 4)),
                .init(model: .genjutsu, mode: .objectSwap, constraints: ModelConstraints(minReferenceImages: 2)),
                .init(
                    model: .seedance25, mode: .motionTransfer,
                    constraints: ModelConstraints(minDuration: 5, maxDuration: 45)),
            ])
    }

    @Test func theRequestLengthKeepsToTheTable() {
        #expect(AccountModel.durationSeconds(of: Self.spec) == 30)
        #expect(AccountModel.durationSeconds(of: Self.spec, constraints: Self.seedance45) == 40)
        let request = AccountModel.request(
            for: Self.spec, model: .seedance25, media: [], constraints: Self.seedance45)
        #expect(request.duration == 40)
    }
}

extension Network {
    @Suite struct ProviderConstraints {
        static let explore = tool("models_explore", "Explore models", ["action", "type", "model_id", "cursor"])

        static func provider(
            tools: [JSONValue], constraints: ModelConstraintTable = .builtIn,
            call: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) -> (HiggsfieldMCPProvider, StubServer) {
            let stub = mcpServer(tools: tools, call: call)
            let tokens = TokenProvider(
                tokens: TokenSet(
                    accessToken: "access-1", refreshToken: nil, expiresAt: .distantFuture, scope: "openid",
                    clientID: "client-1"),
                refresh: { $0 }, persist: { _ in })
            let session = stub.session()
            let client = MCPClient(
                endpoint: URL(string: "https://mcp.higgsfield.ai/mcp")!, tokens: tokens, session: session)
            let provider = HiggsfieldMCPProvider(
                account: HiggsfieldAccount(client: client, session: session), owner: "user_1",
                constraints: { constraints })
            return (provider, stub)
        }

        /// The fallback estimate and the quote before upload both bill the length the table allows.
        @Test func theEstimateBillsTheLengthTheTableAllows() async throws {
            let (builtIn, _) = Self.provider(tools: Provider.fullSet)
            let (cached, _) = Self.provider(
                tools: Provider.fullSet, constraints: AccountModelConstraintsTests.seedance45)
            #expect(try await builtIn.estimate(AccountModelConstraintsTests.spec) == .credits(210, isEstimate: true))
            #expect(try await cached.estimate(AccountModelConstraintsTests.spec) == .credits(280, isEstimate: true))

            let (quoted, stub) = Self.provider(
                tools: Provider.fullSet, constraints: AccountModelConstraintsTests.seedance45
            ) { _, arguments in
                ["cost": ["credits": .number((arguments["params"]?["duration"]?.numberValue ?? 0) * 7)]]
            }
            #expect(try await quoted.estimate(AccountModelConstraintsTests.spec) == .credits(280, isEstimate: false))
            #expect(Provider.calls(stub).map { $0["arguments"]?["params"]?["duration"] } == [40])
        }

        @Test func readsTheConstraintsFromModelsExplore() async throws {
            let (provider, _) = Self.provider(tools: Provider.fullSet + [Self.explore]) { _, arguments in
                guard arguments["model_id"] == "kling3_0_motion_control" else { return [:] }
                return [
                    "parameters": ["duration": ["minimum": 3, "maximum": 10]], "medias": [["role": "image", "max": 1]],
                ]
            }
            let table = try #require(try await provider.modelConstraints())
            #expect(
                table[.klingMotionControl, .motionTransfer]
                    == ModelConstraints(minDuration: 3, maxDuration: 10, maxReferenceImages: 1))
            #expect(table[.seedance25, .motionTransfer] == ModelConstraints())
        }

        /// The snapshot's answers: Seedance's Motion job gets 4–30 s, the rest keep the constants.
        @Test func readsTheSnapshotsAnswers() async throws {
            let seedance = try CatalogSnapshot.value(CatalogSnapshot.seedance)
            let kling = try CatalogSnapshot.value(CatalogSnapshot.kling)
            let motion = try CatalogSnapshot.value(CatalogSnapshot.motionControl)
            let (provider, _) = Self.provider(tools: Provider.fullSet + [Self.explore]) { _, arguments in
                switch arguments["model_id"]?.stringValue {
                case "seedance_2_5": seedance
                case "kling3_0_motion_control": kling
                default: motion
                }
            }
            let table = try #require(try await provider.modelConstraints())
            #expect(table[.seedance25, .motionTransfer] == ModelConstraints(minDuration: 4, maxDuration: 30))
            #expect(table[.klingMotionControl, .motionTransfer] == ModelConstraints())
            #expect(table[.genjutsu, .motionTransfer] == ModelConstraints())
        }

        @Test func withoutModelsExploreThereAreNoConstraints() async throws {
            let (provider, _) = Self.provider(tools: Provider.fullSet)
            #expect(try await provider.modelConstraints() == nil)
        }
    }
}
