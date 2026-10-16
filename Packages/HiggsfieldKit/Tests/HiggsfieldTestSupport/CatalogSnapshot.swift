import Foundation
import HiggsfieldMCP

/// `structuredContent` of `models_explore` answers from the catalog snapshot `docs/mcp-snapshots/2026-10-15.json`,
/// copied as they are (public model catalog data; the account's `unlim` block said it had no allowance).
public enum CatalogSnapshot {
    /// `models_explore {action: "get", model_id: "seedance_2_5"}`.
    public static let seedance = #"""
        {
          "aspect_ratios": ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"],
          "description": "Seedance 2.5 text-to-video, multimodal omni-reference generation, video edit, and video extension",
          "id": "seedance_2_5",
          "medias": [
            {"name": "medias", "roles": ["start_image", "end_image", "image_references", "video_references", "audio_references"], "type": "image"}
          ],
          "name": "Seedance 2.5",
          "output_type": "video",
          "parameters": [
            {"default": "t2v", "description": "Generation mode: 't2v' for prompt-only generation, 'omni_reference' for image, video, or audio references, 'video_edit' to edit one reference video (billed by that video's duration; 'duration' and 'aspect_ratio' are ignored), or 'video_extension' to extend a reference video ('aspect_ratio' is ignored \u2014 the output follows the extended video).", "name": "mode", "options": ["t2v", "omni_reference", "video_edit", "video_extension"], "required": "optional", "type": "string"},
            {"default": 5, "description": "Duration in seconds (4-30).", "max": 30, "min": 4, "name": "duration", "required": "optional", "type": "number"},
            {"default": "720p", "description": "Output resolution: 480p, 720p, or 1080p.", "name": "resolution", "options": ["480p", "720p", "1080p"], "required": "optional", "type": "string"},
            {"default": true, "description": "Generate audio for the output video.", "name": "generate_audio", "required": "optional", "type": "bool"},
            {"default": "standard", "description": "'standard' = normal output bitrate; 'high' = higher bitrate output.", "name": "bitrate_mode", "options": ["standard", "high"], "required": "optional", "type": "string"},
            {"description": "Extension direction; required for mode 'video_extension' and not allowed otherwise.", "name": "extension_mode", "nullable": true, "options": ["backward", "forward"], "required": "optional", "type": "string"},
            {"default": false, "description": "Generate a 480p draft that can be finalized within seven days.", "name": "draft", "required": "optional", "type": "bool"},
            {"description": "Completed draft job to finalize at 1080p.", "name": "draft_job_id", "nullable": true, "required": "optional", "type": "string"}
          ],
          "provider_name": "Bytedance",
          "tags": ["text-to-video", "reference", "identity", "audio-reference", "video-reference", "video-edit", "video-extension", "480p", "720p", "1080p"],
          "unlim": {"available": false, "expires_at": null, "remaining": null}
        }
        """#

    /// `models_explore {action: "get", model_id: "kling3_0_motion_control"}`.
    public static let kling = #"""
        {
          "aspect_ratios": [],
          "description": "",
          "id": "kling3_0_motion_control",
          "medias": [
            {"name": "medias", "roles": ["image_references", "video_references"], "type": "image"}
          ],
          "name": "Kling 3.0 Motion Control",
          "output_type": "video",
          "parameters": [
            {"default": "std", "description": "Motion control quality mode. 'std' = standard, 'pro' = higher quality.", "name": "mode", "options": ["std", "pro"], "required": "optional", "type": "string"},
            {"default": "input_image", "description": "Which input provides the background of the output: the reference image or the reference video.", "name": "background_source", "options": ["input_image", "input_video"], "required": "optional", "type": "string"}
          ],
          "provider_name": "",
          "supports_unlim": true,
          "tags": ["unlim"],
          "unlim": {"available": false, "expires_at": null, "remaining": null}
        }
        """#

    /// `models_explore {action: "get", model_id: "hf_mult_motion_control"}`.
    public static let motionControl = #"""
        {
          "aspect_ratios": [],
          "description": "Transfer motion from a reference video to subjects in reference images",
          "id": "hf_mult_motion_control",
          "medias": [
            {"name": "medias", "roles": ["image_references", "video_references"], "type": "image"}
          ],
          "name": "Genjutsu",
          "output_type": "video",
          "parameters": [
            {"default": "720p", "description": "Output resolution: 480p, 720p, or 1080p.", "name": "resolution", "options": ["480p", "720p", "1080p"], "required": "optional", "type": "string"}
          ],
          "provider_name": "Higgsfield",
          "tags": ["motion-control", "image-to-video", "video-reference", "480p", "720p", "1080p"],
          "unlim": {"available": false, "expires_at": null, "remaining": null}
        }
        """#

    /// The first `models_explore {action: "list", type: "video"}` page, cut to two of its 20 items.
    public static let videoList = #"""
        {
          "has_more": true,
          "items": [
            {"aspect_ratios": ["1:1", "4:3", "3:4", "16:9", "9:16"], "description": "Solid cinematic, dramatic compositions", "durations": [5, 10], "id": "cinematic_studio_video", "medias": [{"name": "medias", "roles": ["image", "start_image", "end_image"], "type": "image"}], "name": "Cinema Studio Video", "output_type": "video", "parameters": [{"default": false, "description": "Enable slow motion effect", "name": "slow_motion", "required": "optional", "type": "bool"}, {"default": true, "description": "Enable sound generation", "name": "sound", "required": "optional", "type": "bool"}], "provider_name": "Higgsfield", "tags": ["cinematic", "dramatic", "compositions", "sound", "slow-motion"]},
            {"aspect_ratios": ["auto", "16:9", "9:16", "4:3", "3:4", "1:1", "21:9"], "description": "Reference-driven video with image/video/audio reference inputs, consistent identity, multi-SKU; optional generate_audio for native audio", "id": "seedance_2_0", "medias": [{"name": "medias", "roles": ["start_image", "end_image", "image_references", "video_references", "audio_references"], "type": "image"}], "name": "Seedance 2.0", "output_type": "video", "parameters": [{"default": 5, "description": "Duration in seconds (4-15).", "max": 15, "min": 4, "name": "duration", "required": "optional", "type": "number"}, {"default": "720p", "description": "Output resolution. 4k/1080p require mode='std'; mode='fast' supports 480p/720p only.", "name": "resolution", "options": ["480p", "720p", "1080p", "4k"], "required": "optional", "type": "string"}, {"default": "std", "description": "'std' = higher quality, supports 480p/720p/1080p/4k, requires a Plus plan or higher (Pro on legacy plans); 'fast' = cheaper/faster, supports 480p/720p only, available from the Basic/Starter plan.", "name": "mode", "options": ["std", "fast"], "required": "optional", "type": "string"}, {"default": "standard", "description": "'standard' = normal output bitrate; 'high' = higher bitrate output.", "name": "bitrate_mode", "options": ["standard", "high"], "required": "optional", "type": "string"}, {"default": "auto", "description": "Cinematic genre hint.", "name": "genre", "options": ["auto", "action", "horror", "comedy", "noir", "drama", "epic"], "required": "optional", "type": "string"}, {"default": true, "description": "Generate native audio for the video. Set false for a silent video. Independent of audio_references.", "name": "generate_audio", "required": "optional", "type": "bool"}], "provider_name": "Bytedance", "supports_unlim": true, "tags": ["reference", "identity", "consistent", "product", "multi-sku", "e-commerce", "audio", "audio-reference", "video-reference", "start-frame", "end-frame", "4k", "high-resolution", "unlim"]}
          ],
          "next_page_token": "20",
          "unlim": {"available": false, "expires_at": null, "remaining": null}
        }
        """#

    /// Four items of the first `models_explore {action: "list", type: "image"}` page (of 20; `has_more: true`):
    /// models that take images as `image` (with a count) and as `image_references`, and one that takes none.
    public static let imageList = #"""
        {
          "has_more": true,
          "items": [
            {"aspect_ratios": ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"], "description": "Realistic UGC, fashion editorial and character generation", "id": "soul_2", "medias": [{"description": "roles: image x1", "max": 1, "name": "medias", "roles": ["image"], "type": "image"}], "name": "Higgsfield Soul 2.0", "output_type": "image", "parameters": [{"default": "2k", "description": "Output quality tier shown as 1.5k or 2k", "name": "quality", "options": ["1.5k", "2k"], "required": "optional", "type": "string"}, {"description": "Soul-ID for personalized generation. Get one from soul_list.", "name": "soul_id", "required": "optional", "type": "string"}], "provider_name": "Higgsfield", "supports_unlim": true, "tags": ["ugc", "fashion", "editorial", "realistic", "character", "character-generation", "soul", "portrait", "v2", "unlim"]},
            {"aspect_ratios": ["1:1", "4:3", "3:4", "16:9", "21:9", "9:16", "3:2", "2:3"], "description": "Next-gen GPT Image model with 1k/2k/4k resolution and low/medium/high quality tiers", "id": "gpt_image_2", "medias": [{"name": "medias", "roles": ["image"], "type": "image"}], "name": "GPT Image 2", "output_type": "image", "parameters": [{"default": "1k", "description": "Output resolution", "name": "resolution", "options": ["1k", "2k", "4k"], "required": "optional", "type": "string"}, {"default": "low", "description": "Image quality", "name": "quality", "options": ["low", "medium", "high"], "required": "optional", "type": "string"}], "provider_name": "OpenAI", "supports_unlim": true, "tags": ["text-rendering", "editing", "typography", "photorealistic", "4k", "high-resolution", "unlim"]},
            {"aspect_ratios": ["16:9"], "description": "Consistent cinematic character identity", "id": "soul_cast", "medias": [], "name": "Soul Cast", "output_type": "image", "parameters": [{"default": 50, "description": "Generation budget (10-500)", "name": "budget", "required": "optional", "type": "number"}], "provider_name": "Higgsfield", "tags": ["character", "identity", "consistent", "cinematic", "persona"]},
            {"aspect_ratios": ["1:1", "3:2", "2:3", "4:3", "3:4", "4:5", "5:4", "9:16", "16:9", "21:9"], "description": "Ultimate quality, text and diagrams", "id": "nano_banana_pro", "medias": [{"name": "medias", "roles": ["image_references"], "type": "image"}], "name": "Nano Banana Pro", "output_type": "image", "parameters": [{"default": "2k", "description": "Output resolution.", "name": "resolution", "options": ["1k", "2k", "4k"], "required": "optional", "type": "string"}], "provider_name": "Google", "supports_unlim": true, "tags": ["quality", "text-rendering", "diagrams", "photorealistic", "versatile", "4k", "text-to-image", "image-to-image", "unlim"]}
          ],
          "next_page_token": "20",
          "unlim": {"available": false, "expires_at": null, "remaining": null}
        }
        """#

    /// One of the answers above as JSON, with the top-level keys in `changes` replaced.
    public static func value(_ text: String, changing changes: [String: JSONValue] = [:]) throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .object(let object) = value else { return value }
        return .object(object.merging(changes) { _, new in new })
    }

    // MARK: - Tool definitions

    /// The snapshot file itself, found from this source file's place in the repository.
    static let snapshot: JSONValue? = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("docs/mcp-snapshots/2026-10-15.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }()

    /// A live answer from `docs/mcp-snapshots/live-2026-10-15/<name>.json`: `{tool, arguments, answer}`, the answer
    /// being the call's `structuredContent`, trimmed, with public catalog URLs or `example.com` ones only; an `isError`
    /// answer also has `isError` and its `text`.
    public static func liveAnswer(_ name: String) throws -> LiveAnswer {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("docs/mcp-snapshots/live-2026-10-15/\(name).json")
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        guard let tool = value["tool"]?.stringValue, let arguments = value["arguments"], let answer = value["answer"]
        else { throw MissingTool(name: name) }
        return LiveAnswer(
            tool: tool, arguments: arguments, answer: answer, isError: value["isError"] == true,
            text: value["text"]?.stringValue)
    }

    /// A call the server answered live, and its answer.
    public struct LiveAnswer: Sendable {
        public var tool: String
        public var arguments: JSONValue
        public var answer: JSONValue
        /// The answer was `isError`, with `text` as its first line.
        public var isError = false
        public var text: String?
    }

    struct MissingTool: Error {
        let name: String
    }

    /// A `tools/list` entry of the snapshot as the server sent it (`name`, `description`, `inputSchema`, …), for a
    /// stub to list, so the client matches its role against the real schema.
    public static func tool(_ name: String) throws -> JSONValue {
        guard let tool = snapshot?["tools"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name }) else {
            throw MissingTool(name: name)
        }
        return tool
    }

    struct MissingModel: Error {
        let id: String
    }

    /// The snapshot's `models_explore {action: "get", model_id: id}` answer (its `structuredContent`), for every
    /// listed video and image model.
    public static func model(_ id: String) throws -> JSONValue {
        guard let model = snapshot?["models"]?["get"]?[id]?["structuredContent"], model.objectValue != nil else {
            throw MissingModel(id: id)
        }
        return model
    }

    /// `generate_video`'s own `params`, which no model schema lists.
    static let toolParams: Set<String> = [
        "model", "prompt", "medias", "use_unlim", "get_cost", "declined_preset_id", "count",
    ]

    /// Where the `params` of a `generate_video` call break the schema `models_explore get` gives for their `model`;
    /// empty when they keep to it. A media role must be one of its `medias[].roles`, `aspect_ratio` one of its
    /// `aspect_ratios`, and every other key one of its `parameters`, of that parameter's type (`number`, `string`,
    /// `bool`, `string_array`) and inside its `options` and `min`…`max`. Throws for a model the snapshot doesn't
    /// describe.
    public static func violations(ofParams params: JSONValue) throws -> [String] {
        guard let object = params.objectValue, let id = object["model"]?.stringValue else { return ["no model"] }
        let model = try model(id)
        var found: [String] = []
        let roles = Set(
            (model["medias"]?.arrayValue ?? []).flatMap { $0["roles"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        for media in object["medias"]?.arrayValue ?? [] {
            let role = media["role"]?.stringValue ?? ""
            if !roles.contains(role) { found.append("\(id): role \(role) isn't one of \(roles.sorted())") }
        }
        let parameters = Dictionary(
            (model["parameters"]?.arrayValue ?? []).compactMap { parameter in
                parameter["name"]?.stringValue.map { ($0, parameter) }
            }, uniquingKeysWith: { first, _ in first })
        for (key, value) in object.sorted(by: { $0.key < $1.key }) where !toolParams.contains(key) {
            if key == "aspect_ratio" {
                if model["aspect_ratios"]?.arrayValue?.contains(value) != true {
                    found.append("\(id): aspect_ratio \(value) isn't listed")
                }
                continue
            }
            guard let parameter = parameters[key] else {
                found.append("\(id): \(key) isn't a parameter")
                continue
            }
            found += violations(of: value, against: parameter, at: "\(id).\(key)")
        }
        return found
    }

    /// One value against one entry of a model's `parameters`.
    static func violations(of value: JSONValue, against parameter: JSONValue, at path: String) -> [String] {
        let typed: Bool =
            switch (parameter["type"]?.stringValue, value) {
            case ("number", .number), ("number", .integer), ("number", .unsignedInteger), ("string", .string),
                ("bool", .bool):
                true
            case ("string_array", .array(let items)): items.allSatisfy { $0.stringValue != nil }
            default: false
            }
        guard typed else { return ["\(path): \(value) isn't a \(parameter["type"] ?? .null)"] }
        var found: [String] = []
        if let options = parameter["options"]?.arrayValue, !options.contains(value) {
            found.append("\(path): \(value) is none of \(options)")
        }
        if let number = value.numberValue {
            if let minimum = parameter["min"]?.numberValue, number < minimum { found.append("\(path): below min") }
            if let maximum = parameter["max"]?.numberValue, number > maximum { found.append("\(path): above max") }
        }
        return found
    }

    /// Where `arguments` break the `inputSchema` of the snapshot's tool `name`; empty when they keep to it. Checks
    /// the parts of JSON Schema the catalog uses: `type`, `properties`, `required`, `additionalProperties: false`,
    /// `enum`, `const`, `anyOf`, `oneOf`, `items`, `minItems`/`maxItems`, `minimum`/`maximum`/`exclusiveMinimum`,
    /// `minLength`/`maxLength` and `pattern`.
    public static func violations(of arguments: JSONValue, sentTo name: String) throws -> [String] {
        guard let schema = try tool(name)["inputSchema"] else { throw MissingTool(name: name) }
        return SchemaCheck.violations(of: arguments, against: schema, at: name)
    }
}

/// A small JSON Schema checker for `CatalogSnapshot.violations(of:sentTo:)`.
enum SchemaCheck {
    static func violations(of value: JSONValue, against schema: JSONValue, at path: String) -> [String] {
        var found: [String] = []
        if let type = schema["type"]?.stringValue, !matches(value, type: type) {
            return ["\(path): not of type \(type)"]
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            found.append("\(path): \(value) is none of \(options)")
        }
        if let constant = schema["const"], constant != value {
            found.append("\(path): \(value) isn't \(constant)")
        }
        found += variants(of: value, in: schema, at: path)
        found += bounds(of: value, in: schema, at: path)
        if case .object(let object) = value { found += properties(of: object, in: schema, at: path) }
        if case .array(let items) = value, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() {
                found += violations(of: item, against: itemSchema, at: "\(path)[\(index)]")
            }
        }
        return found
    }

    static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null),
            ("number", .number), ("number", .integer), ("number", .unsignedInteger), ("integer", .integer),
            ("integer", .unsignedInteger):
            true
        case ("integer", .number(let number)): number == number.rounded()
        default: false
        }
    }

    /// `anyOf` needs one variant to hold, `oneOf` exactly one.
    static func variants(of value: JSONValue, in schema: JSONValue, at path: String) -> [String] {
        var found: [String] = []
        if let anyOf = schema["anyOf"]?.arrayValue,
            !anyOf.contains(where: { violations(of: value, against: $0, at: path).isEmpty })
        {
            found.append("\(path): matches no anyOf variant")
        }
        if let oneOf = schema["oneOf"]?.arrayValue {
            let holding = oneOf.filter { violations(of: value, against: $0, at: path).isEmpty }.count
            if holding != 1 { found.append("\(path): matches \(holding) oneOf variants, not 1") }
        }
        return found
    }

    static func bounds(of value: JSONValue, in schema: JSONValue, at path: String) -> [String] {
        var found: [String] = []
        switch value {
        case .number, .integer, .unsignedInteger:
            guard let number = value.numberValue else { return found }
            if let minimum = schema["minimum"]?.numberValue, number < minimum { found.append("\(path): below minimum") }
            if let maximum = schema["maximum"]?.numberValue, number > maximum { found.append("\(path): above maximum") }
            if let floor = schema["exclusiveMinimum"]?.numberValue, number <= floor {
                found.append("\(path): not above exclusiveMinimum")
            }
        case .string(let text):
            if let minimum = schema["minLength"]?.numberValue, Double(text.count) < minimum {
                found.append("\(path): shorter than minLength")
            }
            if let maximum = schema["maxLength"]?.numberValue, Double(text.count) > maximum {
                found.append("\(path): longer than maxLength")
            }
            if let pattern = schema["pattern"]?.stringValue, text.range(of: pattern, options: .regularExpression) == nil
            {
                found.append("\(path): \"\(text)\" doesn't match the pattern")
            }
        case .array(let items):
            if let minimum = schema["minItems"]?.numberValue, Double(items.count) < minimum {
                found.append("\(path): fewer than minItems")
            }
            if let maximum = schema["maxItems"]?.numberValue, Double(items.count) > maximum {
                found.append("\(path): more than maxItems")
            }
        default:
            break
        }
        return found
    }

    static func properties(of object: [String: JSONValue], in schema: JSONValue, at path: String) -> [String] {
        var found: [String] = []
        let properties = schema["properties"]?.objectValue ?? [:]
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            found.append("\(path): missing \(key)")
        }
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            if let property = properties[key] {
                found += violations(of: value, against: property, at: "\(path).\(key)")
            } else if schema["additionalProperties"] == false {
                found.append("\(path): \(key) isn't allowed")
            }
        }
        return found
    }
}
