import Foundation
import HiggsfieldMCP
import JutsuAgent

/// The MCP tools, one per app command, in the order `tools/list` gives them. Arguments are snake_case, as MCP tools
/// usually are; the app's answer keeps its own camelCase JSON.
enum Tool: String, CaseIterable {
    case capabilities, show

    /// The command for these arguments, or the tool error that tells the model what to fix. Checked here before
    /// anything reaches the app, and again by the app as it decodes the command.
    func command(_ arguments: [String: JSONValue]) -> Result<AgentCommand, AgentError> {
        do throws(AgentError) {
            let given = Arguments(tool: rawValue, values: arguments)
            switch self {
            case .capabilities:
                try given.allow(["models", "model"])
                let model = try given.string("model")
                if let model, !AgentNames.isValidModelID(model) {
                    throw .badRequest("capabilities: model is a model ID, such as seedance25")
                }
                let models = try given.bool("models")
                return .success(.capabilities(CapabilitiesCommand(models: models || model != nil, model: model)))
            case .show:
                try given.allow(["page", "job"])
                switch (try given.string("page"), try given.string("job")) {
                case (let page?, nil):
                    guard let page = AgentPage(rawValue: page) else {
                        throw .badRequest("show: page is one of \(Self.pageNames)")
                    }
                    return .success(.show(.page(page)))
                case (nil, let job?):
                    guard let id = UUID(uuidString: job) else { throw .badRequest("show: job is a job ID (a UUID)") }
                    return .success(.show(.job(id)))
                default:
                    throw .badRequest("show takes exactly one of page (\(Self.pageNames)) or job (a job ID)")
                }
            }
        } catch {
            return .failure(error)
        }
    }

    static let pageNames = AgentPage.allCases.map(\.rawValue).joined(separator: ", ")
}

/// A tool's arguments, read strictly: a key the tool doesn't take or a value of the wrong type is an error that
/// names it, never a crash or a silent default.
struct Arguments {
    let tool: String
    let values: [String: JSONValue]

    func allow(_ keys: Set<String>) throws(AgentError) {
        if let unknown = values.keys.sorted().first(where: { !keys.contains($0) }) {
            let known = keys.sorted().joined(separator: ", ")
            throw .badRequest("\(tool) takes \(known.isEmpty ? "no arguments" : known), not '\(unknown.prefix(64))'")
        }
    }

    /// nil when left out or null.
    func string(_ key: String) throws(AgentError) -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw .badRequest("\(tool): \(key) is a string")
        }
    }

    /// `false` when left out or null.
    func bool(_ key: String) throws(AgentError) -> Bool {
        switch values[key] {
        case nil, .null?: return false
        case .bool(let value)?: return value
        default: throw .badRequest("\(tool): \(key) is true or false")
        }
    }
}
