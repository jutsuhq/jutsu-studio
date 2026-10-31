import HiggsfieldMCP
import JutsuAgent

extension Tool {
    /// `create_element`'s input, but its `request_id`.
    static let createElementProperties: [String: JSONValue] = [
        "name": [
            "type": "string", "maxLength": .number(Double(CreateElementCommand.maxNameLength)),
            "description": "What elements and create_video's and create_image's elements call it.",
        ],
        "category": [
            "type": "string", "enum": .array(ElementsCommand.categories.map { .string($0) }),
            "description": "character when left out.",
        ],
        "images": [
            "type": "array", "minItems": 1, "maxItems": .number(Double(CreateElementCommand.maxImages)),
            "items": ["type": "string"],
            "description": "Clear images of the subject on this Mac, in order; the first is its face or front.",
        ],
    ]
}
