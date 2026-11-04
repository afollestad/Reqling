import Foundation
import MCP

/// One tool on Reqling's MCP server: what clients see (`definition`) and the handler that serves it, together, so a
/// listed tool can never lack a handler.
@MainActor
public struct MCPTool {
    public let definition: Tool
    /// Long enough for the tool's slowest honest call; `MCPToolDispatcher` ends a call that outlives it.
    public let timeout: Duration
    let handler: @MainActor (MCPArguments) async throws -> MCPToolResult

    public var name: String {
        definition.name
    }

    /// `properties` and `required` describe the arguments; the schema is always a strict object root, since some
    /// clients drop tools whose input schema is anything else. Handlers still validate through `MCPArguments`.
    init(
        _ name: String,
        title: String,
        description: String,
        properties: [String: Value] = [:],
        required: [String] = [],
        annotations: MCPToolAnnotations,
        timeout: Duration = .seconds(30),
        handler: @escaping @MainActor (MCPArguments) async throws -> MCPToolResult
    ) {
        definition = Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: MCPSchema.object(properties, required: required),
            annotations: Tool.Annotations(
                title: title,
                readOnlyHint: annotations.readOnly,
                destructiveHint: annotations.destructive,
                idempotentHint: annotations.idempotent,
                openWorldHint: annotations.openWorld
            )
        )
        self.timeout = timeout
        self.handler = { arguments in
            try arguments.requireOnly(Set(properties.keys))
            return try await handler(arguments)
        }
    }
}

/// The hints MCP clients use to decide what to confirm. Every deletion here moves files to the Trash, so none is
/// destructive in the irreversible sense the hint means.
public struct MCPToolAnnotations: Sendable {
    let readOnly: Bool
    let destructive: Bool
    let idempotent: Bool
    /// Whether the tool reaches beyond Reqling's own data: sending requests and asking servers for their schema.
    let openWorld: Bool

    static let read = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true, openWorld: false)
    static let edit = MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true, openWorld: false)
    /// Creates something new on each call, such as a project or a duplicate.
    static let create = MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false, openWorld: false)
    static let network = MCPToolAnnotations(readOnly: false, destructive: false, idempotent: false, openWorld: true)
    static let networkRead = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true, openWorld: true)
}

/// A tool's answer. `structuredContent` carries the data; `text` repeats it as JSON, since some clients show only the
/// text.
public struct MCPToolResult: Sendable, Equatable {
    public let text: String
    public let structuredContent: Value?
    public let isError: Bool

    public init(text: String, structuredContent: Value? = nil, isError: Bool = false) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }

    /// `content`, which must be an object, as both the structured result and its JSON text.
    static func object(_ content: [String: Value]) -> MCPToolResult {
        MCPToolResult(text: MCPJSON.text(.object(content)), structuredContent: .object(content))
    }

    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, isError: true)
    }
}

/// A call that cannot be served as asked. The message goes back to the agent, so it says what to change.
public struct MCPToolError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// Converts between `Value` and JSON text.
enum MCPJSON {
    /// Sorted keys, so the text is stable from call to call.
    static func text(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// `value` as `Model`, through the same JSON its `Codable` conformance reads from disk.
    static func decode<Model: Decodable>(_ type: Model.Type, from value: Value, path: String) throws -> Model {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw MCPToolError("`\(path)` is not valid: \(Self.describe(error))")
        } catch {
            throw MCPToolError("`\(path)` is not valid: \(error.localizedDescription)")
        }
    }

    static func encode<Model: Encodable>(_ model: Model) throws -> Value {
        let data = try JSONEncoder().encode(model)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return keys.isEmpty ? "" : " at `\(keys.hasPrefix(".") ? String(keys.dropFirst()) : keys)`"
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.debugDescription + path(context)
        case .keyNotFound(let key, let context):
            return "missing `\(key.stringValue)`" + path(context)
        @unknown default:
            return error.localizedDescription
        }
    }
}
