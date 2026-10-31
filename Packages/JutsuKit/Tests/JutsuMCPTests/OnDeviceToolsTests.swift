import Foundation
import HiggsfieldMCP
import JutsuAgent
import Testing

@testable import JutsuMCP

/// enhance on this Mac and the sheet show opens, as the helper turns them into commands and lists them.
@Suite struct OnDeviceToolsTests {
    private let item = JSONValue.string(UUID().uuidString)

    private func enhance(_ arguments: [String: JSONValue]) -> Result<AgentCommand, AgentError> {
        var all: [String: JSONValue] = ["request_id": "run-1", "item": item]
        for (key, value) in arguments { all[key] = value }
        return Tool.enhance.command(all)
    }

    private func command(_ arguments: [String: JSONValue]) throws -> EnhanceCommand {
        guard case .success(.enhance(let command)) = enhance(arguments) else {
            throw AgentError.badRequest("no enhance for \(arguments)")
        }
        return command
    }

    @Test func aRunOnThisMacNeedsNoMaxCostAndIgnoresOne() throws {
        let smooth = try command(["operation": "smooth_motion", "mode": "slow_4x"])
        #expect(smooth.maxCost == nil && smooth.mode == "slow_4x" && smooth.isOnDevice)
        let paidFor = try command([
            "operation": "smooth_motion", "mode": "slow_4x", "max_cost": ["amount": 5, "unit": "credits"],
        ])
        #expect(paidFor.maxCost == nil && paidFor.fingerprint == smooth.fingerprint)
        let upscale = try command(["operation": "upscale", "engine": "mac"])
        #expect(upscale.maxCost == nil && upscale.isOnDevice)
        // A malformed max_cost on a free run is no reason to refuse it.
        #expect(try command(["operation": "upscale", "engine": "mac", "max_cost": "free"]).isOnDevice)
    }

    @Test func theFingerprintFollowsWhatTheRunIs() throws {
        let first = try command(["operation": "smooth_motion", "mode": "60fps"])
        #expect(try command(["operation": "smooth_motion", "mode": "60fps"]).fingerprint == first.fingerprint)
        #expect(try command(["operation": "smooth_motion", "mode": "slow_2x"]).fingerprint != first.fingerprint)
        #expect(
            try command(["operation": "smooth_motion", "mode": "60fps", "engine": "mac"]).fingerprint
                != first.fingerprint)
        #expect(AgentNames.isValidFingerprint(first.fingerprint))
    }

    @Test func badOnDeviceArgumentsAreRefusedBeforeTheApp() {
        let cases: [[String: JSONValue]] = [
            ["operation": "smooth_motion"], ["operation": "smooth_motion", "mode": "120fps"],
            ["operation": "smooth_motion", "mode": 60],
            ["operation": "smooth_motion", "mode": "60fps", "engine": "standard"],
            ["operation": "upscale", "engine": "mac", "frame_rate": 60],
            ["operation": "upscale", "engine": "mac", "target": "4k", "aspect_ratio": "9:16"],
            ["operation": "upscale", "engine": "standard"],
            ["operation": "upscale"], ["operation": "reframe", "aspect_ratio": "9:16", "mode": "60fps"],
        ]
        for arguments in cases {
            guard case .failure(let error) = enhance(arguments) else {
                Issue.record("taken: \(arguments)")
                continue
            }
            #expect(error.code == .badRequest, "\(arguments)")
        }
    }

    /// The helper and the app refuse the same enhance and show with the same words, as for the other tools.
    @Test func theHelperAndTheAppRefuseWithTheSameWords() throws {
        let fingerprint = JSONValue.string(String(repeating: "0", count: 64))
        let cases: [(String, [String: JSONValue])] = [
            ("enhance", ["operation": "smooth_motion"]), ("enhance", ["operation": "smooth_motion", "mode": "90fps"]),
            ("enhance", ["operation": "smooth_motion", "mode": "60fps", "engine": "topaz"]),
            ("enhance", ["operation": "upscale", "engine": "mac", "target": "2k", "mode": "60fps"]),
            ("show", ["item": item]), ("show", ["sheet": "upscale_on_mac"]),
            ("show", ["page": "library", "item": item, "sheet": "upscale_on_mac"]),
        ]
        for (tool, arguments) in cases {
            var given = arguments
            if tool == "enhance" {
                given["request_id"] = "run-1"
                given["item"] = item
            }
            guard case .failure(let helper) = Tool(rawValue: tool)?.command(given) else {
                Issue.record("\(tool) \(arguments) taken")
                continue
            }
            var fields = Dictionary(
                uniqueKeysWithValues: given.map { key, value in
                    (key == "request_id" ? "requestId" : key, value)
                })
            if tool == "enhance" { fields["fingerprint"] = fingerprint }
            fields["version"] = 1
            fields["command"] = .string(tool)
            guard case .failure(let app) = AgentWire.request(from: try JSONEncoder().encode(fields)).request else {
                Issue.record("\(tool) \(arguments) decoded")
                continue
            }
            let named = tool == "show" ? "Malformed request: " : "Malformed request: \(tool): "
            #expect(helper.message == app.message.replacingOccurrences(of: "Malformed request: ", with: named))
        }
    }

    @Test func showOpensAnItemsSheet() {
        let id = UUID()
        guard
            case .success(let command) = Tool.show.command([
                "item": .string(id.uuidString), "sheet": "upscale_on_mac",
            ])
        else {
            Issue.record("show item refused")
            return
        }
        #expect(command == .show(.sheet(.upscaleOnMac, item: id)))
        guard case .failure(let error) = Tool.show.command(["item": .string(id.uuidString), "sheet": "smooth"]) else {
            Issue.record("an unknown sheet was taken")
            return
        }
        #expect(error.message == "Malformed request: show: sheet is one of upscale_on_mac, subtitles.")
    }

    @Test func theSchemasStateTheOnDeviceOptions() {
        let enhance = Tool.enhance.definition(structured: true)
        let properties = enhance["inputSchema"]?["properties"]
        #expect(enhance["inputSchema"]?["required"] == ["request_id", "item", "operation"])
        #expect(properties?["engine"]?["enum"] == ["standard", "mac"])
        #expect(properties?["mode"]?["enum"] == ["60fps", "slow_2x", "slow_4x"])
        #expect(properties?["operation"]?["enum"]?.arrayValue?.contains("smooth_motion") == true)
        let show = Tool.show.definition(structured: true)["inputSchema"]?["properties"]
        #expect(show?["sheet"]?["enum"] == ["upscale_on_mac", "subtitles"])
        #expect(show?["item"]?["format"] == "uuid")
        let job = Tool.jobs.definition(structured: true)["outputSchema"]?["properties"]?["jobs"]?["items"]
        #expect(job?["properties"]?["estimatedSeconds"] != nil && job?["properties"]?["item"] != nil)
        let capabilities = Tool.capabilities.definition(structured: true)["outputSchema"]?["properties"]
        #expect(capabilities?["onDevice"]?["properties"]?["upscaleImage"] != nil)
        #expect(capabilities?["window"]?["properties"]?["open"] != nil)
        #expect(capabilities?["window"]?["properties"]?["menuBarMode"] != nil)
    }
}
