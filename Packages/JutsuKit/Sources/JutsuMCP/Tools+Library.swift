import Foundation
import HiggsfieldMCP
import JutsuAgent

// The parsers of create_image and the Library tools, kept apart from the video tools in Tools.swift.
extension Tool {
    static func createImage(_ given: Arguments, workingDirectory: URL) throws(AgentError) -> AgentCommand {
        try given.allow([
            "request_id", "model", "prompt", "aspect_ratio", "count", "inputs", "input", "elements", "max_cost",
            "title",
        ])
        let requestID = try given.requestID()
        let maxCost = try given.maxCost()
        guard let prompt = try given.string("prompt") else {
            throw .badRequest("create_image needs prompt, the image to make")
        }
        // input is the one-image form of inputs; an agent sends one or the other.
        let input = try given.string("input")
        var inputs = try given.strings("inputs")
        if let input {
            guard inputs.isEmpty, given.values["inputs"] == nil || given.values["inputs"] == .null else {
                throw .badRequest("create_image: \(AgentImageRequest.bothInputs)")
            }
            inputs = [input]
        }
        var image = AgentImageRequest(
            model: try given.string("model"), prompt: prompt, aspectRatio: try given.string("aspect_ratio"),
            count: try given.int("count"), inputs: inputs, elements: try given.strings("elements"),
            title: try given.string("title"))
        if let problem = image.problem { throw .badRequest("create_image: \(problem)") }
        image.inputs = image.inputs.map { Inbox.resolve($0, from: workingDirectory).path(percentEncoded: false) }
        let fingerprint = try Self.fingerprint("create_image", image, files: image.inputs, maxCost)
        return .createImage(
            CreateImageCommand(requestID: requestID, fingerprint: fingerprint, image: image, maxCost: maxCost))
    }

    static func librarySearch(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow([
            "query", "kind", "starred", "verdict", "include_rejected", "model", "mode", "from", "to", "limit", "cursor",
            "include_higgsfield", "refresh_higgsfield",
        ])
        let kind = try given.string("kind").map { name throws(AgentError) -> AgentLibraryKind in
            guard let kind = AgentLibraryKind(rawValue: name) else {
                throw .badRequest("library_search: kind is all, video or image")
            }
            return kind
        }
        let verdict = try given.string("verdict").map { name throws(AgentError) -> AgentVerdict in
            guard let verdict = AgentVerdict(rawValue: name) else {
                throw .badRequest("library_search: verdict is unreviewed, kept or rejected")
            }
            return verdict
        }
        let command = LibrarySearchCommand(
            query: try given.string("query"), kind: kind, starred: try given.optionalBool("starred"), verdict: verdict,
            includeRejected: try given.optionalBool("include_rejected"), model: try given.string("model"),
            mode: try given.string("mode"), from: try given.date("from"), to: try given.date("to"),
            limit: try given.int("limit"), cursor: try given.string("cursor"),
            includeHiggsfield: try given.optionalBool("include_higgsfield"),
            refreshHiggsfield: try given.optionalBool("refresh_higgsfield"))
        if let problem = command.problem { throw .badRequest("library_search: \(problem)") }
        return .librarySearch(command)
    }

    static func libraryGet(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["ids"])
        let command = LibraryGetCommand(ids: try given.ids("ids"))
        if let problem = command.problem { throw .badRequest("library_get: \(problem)") }
        return .libraryGet(command)
    }

    static func elements(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["query", "category", "limit", "cursor"])
        let command = ElementsCommand(
            query: try given.string("query"), category: try given.string("category"), limit: try given.int("limit"),
            cursor: try given.string("cursor"))
        if let problem = command.problem { throw .badRequest("elements: \(problem)") }
        return .elements(command)
    }

    static func libraryDownload(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["ids"])
        let command = LibraryDownloadCommand(ids: try given.ids("ids"))
        if let problem = command.problem { throw .badRequest("library_download: \(problem)") }
        return .libraryDownload(command)
    }

    static func libraryMark(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["ids", "verdict", "star"])
        let verdict = try given.string("verdict").map { name throws(AgentError) -> AgentCulling in
            guard let verdict = AgentCulling(rawValue: name) else {
                throw .badRequest("library_mark: verdict is keep, reject or clear")
            }
            return verdict
        }
        let command = LibraryMarkCommand(
            ids: try given.ids("ids"), verdict: verdict, star: try given.optionalBool("star"))
        if let problem = command.problem { throw .badRequest("library_mark: \(problem)") }
        return .libraryMark(command)
    }

    static func enhance(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow([
            "request_id", "item", "operation", "target", "frame_rate", "engine", "aspect_ratio", "language", "voice",
            "max_cost",
        ])
        let requestID = try given.requestID()
        let maxCost = try given.maxCost()
        guard let item = try given.string("item").flatMap(UUID.init(uuidString:)) else {
            throw .badRequest("enhance needs item, a video's Library ID from library_search")
        }
        guard let name = try given.string("operation"), let operation = AgentEnhancement(rawValue: name) else {
            let names = AgentEnhancement.allCases.map(\.rawValue).joined(separator: ", ")
            throw .badRequest("enhance needs operation, one of \(names)")
        }
        var command = EnhanceCommand(
            requestID: requestID, fingerprint: String(repeating: "0", count: 64), item: item, operation: operation,
            target: try given.string("target"), frameRate: try given.int("frame_rate"),
            engine: try given.string("engine"), aspectRatio: try given.string("aspect_ratio"),
            language: try given.string("language"), voice: try given.string("voice"), maxCost: maxCost)
        if let problem = command.problem { throw .badRequest("enhance: \(problem)") }
        command.fingerprint = try Self.fingerprint("enhance", command, files: [], maxCost)
        return .enhance(command)
    }

    static func deliverySet(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["action", "name", "items", "set", "folder", "wait_seconds"])
        guard let name = try given.string("action"), let action = AgentDeliveryAction(rawValue: name) else {
            throw .badRequest("delivery_set needs action: create, list or export")
        }
        let set = try given.string("set").map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("delivery_set: set is a set ID") }
            return id
        }
        let command = DeliverySetCommand(
            action: action, name: try given.string("name"), items: try given.ids("items"), set: set,
            folder: try given.string("folder"), waitSeconds: try given.int("wait_seconds"))
        if let problem = command.problem { throw .badRequest("delivery_set: \(problem)") }
        return .deliverySet(command)
    }

    static func frames(_ given: Arguments, workingDirectory: URL) throws(AgentError) -> AgentCommand {
        try given.allow(["item", "file", "times", "compare_item", "compare_file", "compare_source"])
        let id = { (key: String) throws(AgentError) -> UUID? in
            try given.string(key).map { text throws(AgentError) -> UUID in
                guard let id = UUID(uuidString: text) else { throw .badRequest("frames: \(key) is a Library item ID") }
                return id
            }
        }
        let times: [Double]
        switch given.values["times"] {
        case .array(let values)?:
            times = try values.map { value throws(AgentError) -> Double in
                guard let number = value.numberValue, number.isFinite else {
                    throw .badRequest("frames: times is a list of seconds")
                }
                return number
            }
        case nil, .null?:
            throw .badRequest("frames needs times, the seconds to take frames at, such as [1, 2.5]")
        default:
            throw .badRequest("frames: times is a list of seconds")
        }
        var command = FramesCommand(
            item: try id("item"), file: try given.string("file"), times: times, compareItem: try id("compare_item"),
            compareFile: try given.string("compare_file"), compareSource: try given.bool("compare_source"))
        if let problem = command.problem { throw .badRequest("frames: \(problem)") }
        let local = { (path: String) in Inbox.resolve(path, from: workingDirectory).path(percentEncoded: false) }
        command.file = command.file.map(local)
        command.compareFile = command.compareFile.map(local)
        return .frames(command)
    }

    /// What names a `frames` command's uploads: it isn't a paid request, so its ID is made from its fingerprint.
    static func uploadRequest(for command: FramesCommand) throws(AgentError) -> UploadRequest {
        let fingerprint: String
        do {
            fingerprint = try AgentFingerprint.of(command)
        } catch {
            throw .badRequest("frames: the parameters can't be read")
        }
        return UploadRequest(command: "frames", requestID: "frames-\(fingerprint.prefix(16))", fingerprint: fingerprint)
    }

    static func export(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["items", "preset", "sidecar", "wait_seconds"])
        guard let name = try given.string("preset"), let preset = AgentExportPreset(rawValue: name) else {
            let names = AgentExportPreset.allCases.map(\.rawValue).joined(separator: ", ")
            throw .badRequest("export needs preset, one of \(names)")
        }
        let command = ExportCommand(
            items: try given.ids("items"), preset: preset, sidecar: try given.optionalBool("sidecar"),
            waitSeconds: try given.int("wait_seconds"))
        if let problem = command.problem { throw .badRequest("export: \(problem)") }
        return .export(command)
    }
}
