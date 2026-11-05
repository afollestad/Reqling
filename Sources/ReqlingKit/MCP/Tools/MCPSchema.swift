import MCP

/// JSON Schema builders for tool arguments. Every object is strict (`additionalProperties: false`), so an unadvertised
/// field is refused rather than ignored; `MCPArguments` enforces the same at the root whatever a client sends.
enum MCPSchema {
    static func object(_ properties: [String: Value], required: [String] = [], description: String? = nil) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(Value.string))
        }
        if let description {
            schema["description"] = .string(description)
        }
        return .object(schema)
    }

    /// An object whose fields are open: a request spec, an auth, or a patch, validated by decoding into the model.
    static func openObject(_ description: String) -> Value {
        ["type": "object", "description": .string(description)]
    }

    static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum {
            schema["minimum"] = .int(minimum)
        }
        if let maximum {
            schema["maximum"] = .int(maximum)
        }
        return .object(schema)
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> Value {
        var schema: [String: Value] = ["type": "number", "description": .string(description)]
        if let minimum {
            schema["minimum"] = .double(minimum)
        }
        if let maximum {
            schema["maximum"] = .double(maximum)
        }
        return .object(schema)
    }

    static func enumeration(_ values: [String], _ description: String) -> Value {
        ["type": "string", "enum": .array(values.map(Value.string)), "description": .string(description)]
    }

    static func array(_ items: Value, _ description: String, minItems: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "array", "items": items, "description": .string(description)]
        if let minItems {
            schema["minItems"] = .int(minItems)
        }
        return .object(schema)
    }

    static func stringMap(_ description: String) -> Value {
        ["type": "object", "additionalProperties": ["type": "string"], "description": .string(description)]
    }

    // MARK: - Shared arguments

    static let project = string("The project's ID, or its exact name when that is unique.")
    /// For tools that edit variables, which can reach Global without one.
    static let variablesProject = string("The project's ID, or its exact name when that is unique. Not needed for Global.")
    /// For tools that edit variables, where leaving it out means the project-wide values.
    static let variablesEnvironment = string(
        "An environment's ID or name, or `Global` for the variables every project shares. Omit for the project's Default."
    )
    /// For tools that resolve or send, where leaving it out means what the window would use.
    static let runEnvironment = string("An environment's ID or name. Omit for the project's active environment.")
    static let request = string("The request's ID, from list_requests.")
    static let folder = string("A folder's ID, from get_project or list_requests. Omit for the project's top level.")
    static let index = integer("Position among the destination's items, from 0. Omit to append.", minimum: 0)
}
