import Foundation
import Testing

@testable import JutsuAgent

/// enhance on this Mac on the wire: free runs without max_cost, the sheet show opens, and what jobs and capabilities say
/// of them.
@Suite struct OnDeviceWireTests {
    private let fingerprint = String(repeating: "a", count: 64)

    private func roundTrip(_ command: AgentCommand) throws -> AgentCommand {
        let line = try AgentWire.line(AgentRequest(command, id: "1"))
        return try AgentWire.request(from: line.dropLast()).request.get().command
    }

    private func enhance(
        _ operation: AgentEnhancement, engine: String? = nil, mode: String? = nil, target: String? = nil,
        maxCost: AgentAmount? = nil
    ) -> EnhanceCommand {
        EnhanceCommand(
            requestID: "r-1", fingerprint: fingerprint, item: UUID(), operation: operation, target: target,
            engine: engine, mode: mode, maxCost: maxCost)
    }

    @Test func onDeviceRunsRoundTripWithoutMaxCost() throws {
        let commands: [AgentCommand] = [
            .enhance(enhance(.smoothMotion, mode: "slow_2x")),
            .enhance(enhance(.smoothMotion, engine: "mac", mode: "60fps")),
            .enhance(enhance(.upscale, engine: "mac")),
            .enhance(enhance(.upscale, target: "4k", maxCost: AgentAmount(20, .credits))),
            .show(.sheet(.upscaleOnMac, item: UUID())),
        ]
        for command in commands {
            #expect(try roundTrip(command) == command)
        }
        let line = try AgentWire.line(AgentRequest(.enhance(enhance(.upscale, engine: "mac"))))
        #expect(!String(decoding: line, as: UTF8.self).contains("maxCost"))
    }

    @Test func onlyRunsOnThisMacGoWithoutMaxCost() {
        #expect(enhance(.smoothMotion, mode: "60fps").problem == nil)
        #expect(enhance(.upscale, engine: "mac").problem == nil)
        #expect(enhance(.upscale).problem?.contains("needs max_cost") == true)
        #expect(enhance(.upscale, engine: "standard").problem?.contains("needs max_cost") == true)
        #expect(enhance(.upscale, engine: "standard", maxCost: AgentAmount(1, .credits)).problem == nil)
        #expect(enhance(.upscale).isOnDevice == false && enhance(.smoothMotion, mode: "60fps").isOnDevice)
    }

    @Test func eachOnDeviceRunTakesOnlyItsOwnOptions() {
        #expect(enhance(.smoothMotion).problem == "smooth_motion needs mode: 60fps, slow_2x, slow_4x")
        #expect(enhance(.smoothMotion, mode: "120fps").problem == "mode is one of 60fps, slow_2x, slow_4x")
        #expect(
            enhance(.smoothMotion, engine: "standard", mode: "60fps").problem
                == "smooth_motion runs on this Mac only: engine is mac or left out")
        #expect(enhance(.upscale, engine: "mac", target: "4k").problem == "upscale with engine mac takes no target")
        #expect(
            enhance(.upscale, engine: "mac", mode: "60fps").problem == "upscale with engine mac takes no mode")
        #expect(
            enhance(.reframe, mode: "60fps", maxCost: AgentAmount(1, .credits)).problem == "reframe takes no mode")
    }

    @Test func aDecodedOnDeviceRunIsCheckedLikeTheHelpersOne() {
        let item = UUID().uuidString
        let line =
            #"{"version":1,"command":"enhance","requestId":"r-1","fingerprint":"\#(fingerprint)","item":"\#(item)","#
            + #""operation":"smooth_motion","mode":"90fps"}"#
        guard case .failure(let error) = AgentWire.request(from: Data(line.utf8)).request else {
            Issue.record("a bad mode decoded")
            return
        }
        #expect(error.message == "Malformed request: mode is one of 60fps, slow_2x, slow_4x.")
    }

    @Test func showTakesAnItemOnlyWithASheet() {
        #expect(ShowCommand.problem(hasPage: false, hasJob: false, hasItem: true, hasSheet: true) == nil)
        #expect(ShowCommand.problem(hasPage: false, hasJob: false, hasItem: true, hasSheet: false) != nil)
        #expect(ShowCommand.problem(hasPage: true, hasJob: false, hasItem: true, hasSheet: true) != nil)
        #expect(ShowCommand.problem(hasPage: true, hasJob: false, hasItem: false, hasSheet: true) != nil)
        let item = UUID().uuidString
        let line = #"{"version":1,"command":"show","item":"\#(item)","sheet":"upscale_on_mac"}"#
        #expect(
            (try? AgentWire.request(from: Data(line.utf8)).request.get().command)
                == .show(.sheet(.upscaleOnMac, item: UUID(uuidString: item) ?? UUID())))
    }

    @Test func anOnDeviceRunAndTheEnginesReadBack() throws {
        let job = AgentJob(
            id: UUID(), state: "processing", progress: 0.4, price: AgentAmount(0, .credits), isPriceExact: true,
            kind: "on_device", requestID: "r-1", mode: "slow_2x", operation: "smooth_motion", item: UUID(),
            estimatedSeconds: 12.5, createdAt: Date(timeIntervalSince1970: 1))
        let engines = AgentCapabilities.OnDevice(
            smoothMotion: .init(available: true, model: "none"),
            upscaleVideo: .init(available: true, maxLongSide: 1280, maxShortSide: 720, model: "needs_consent"),
            upscaleImage: .init(available: false, maxLongSide: 1920, maxShortSide: 1080, model: "agreed"))
        var capabilities = AgentCapabilities(appVersion: "1", connection: .init(kind: .none), budget: nil)
        capabilities.onDevice = engines
        let response = AgentResponse(capabilities: capabilities, jobs: AgentJobs(jobs: [job]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try decoder.decode(AgentResponse.self, from: encoder.encode(response))
        #expect(back == response)
        #expect(engines.modes == ["60fps", "slow_2x", "slow_4x"])
    }
}
