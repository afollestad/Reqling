import Foundation

/// Converts between proto3 JSON and the protobuf binary wire format for any message a `DescriptorRegistry` defines,
/// with no generated code: there is no maintained Swift dynamic-message library.
///
/// It follows protobuf's proto3 JSON mapping, including every well-known type's JSON form, which it handles from
/// built-in layouts so a schema that omits `google/protobuf/*.proto` still works. proto2 groups and editions
/// `DELIMITED` messages use the group wire form both ways; extensions are treated as unknown fields.
public struct ProtobufJSONCodec: Sendable {
    public let registry: DescriptorRegistry

    public init(registry: DescriptorRegistry) {
        self.registry = registry
    }

    /// Encodes proto3 JSON (`{"name": "Ada"}`) as `messageType`'s wire bytes. Fields accept their JSON name or their
    /// proto name; unknown fields, mistyped values, and out-of-range numbers throw with the offending path.
    public func encode(json: String, as messageType: String) throws(GRPCCodecError) -> [UInt8] {
        let value = try ProtoJSONParser.parse(json)
        return try encodeMessage(value, typeName: DescriptorRegistry.normalized(messageType), depth: 0)
    }

    /// Decodes wire bytes as `messageType` into pretty-printed proto3 JSON, fields in declaration order. Unknown
    /// fields are dropped and proto3 implicit fields at their default are omitted, as the JSON mapping specifies.
    public func decode(_ bytes: [UInt8], as messageType: String) throws(GRPCCodecError) -> String {
        try decodeCountingUnknownFields(bytes, as: messageType).json
    }

    /// `decode(_:as:)`, plus how many fields it dropped because the schema does not define them (or defines them with
    /// another wire type), at any depth: each message counts its distinct field numbers. A nonzero count usually means
    /// the schema is older than the server's.
    public func decodeCountingUnknownFields(
        _ bytes: [UInt8],
        as messageType: String
    ) throws(GRPCCodecError) -> (json: String, unknownFieldCount: Int) {
        var unknown = 0
        let value = try decodeMessage(bytes[...], typeName: DescriptorRegistry.normalized(messageType), depth: 0, unknown: &unknown)
        return (value.prettyPrinted(), unknown)
    }

    /// A pretty-printed JSON message with every field present at a placeholder value, for the editor's Example fill.
    /// Repeated fields and maps get one element and a oneof its first member; a message that contains itself, or one
    /// past the size bounds, stops at `{}`.
    public func example(for messageType: String) -> String {
        var budget = ExampleBudget()
        return exampleMessage(DescriptorRegistry.normalized(messageType), ancestors: [], budget: &budget).prettyPrinted()
    }
}

/// A message that does not match its schema; `path` names the field, such as `user.emails[2]`.
public struct GRPCCodecError: Error, Hashable, Sendable, LocalizedError {
    public let message: String
    public let path: String?

    public init(_ message: String, path: String? = nil) {
        self.message = message
        self.path = path
    }

    public var errorDescription: String? {
        path.map { "\($0): \(message)" } ?? message
    }

    /// The same error one level further out, as it unwinds: `segment` is a field name, `[2]`, or `["key"]`.
    /// Building paths only on failure keeps the success path free of string work.
    func prefixed(with segment: String) -> GRPCCodecError {
        guard let path else {
            return GRPCCodecError(message, path: segment)
        }
        return GRPCCodecError(message, path: path.hasPrefix("[") ? segment + path : "\(segment).\(path)")
    }
}

extension ProtobufJSONCodec {
    /// Bounds message nesting in both directions, matching protobuf's default recursion limit.
    static let maxDepth = 100

    /// The registry's schema, falling back to built-in ones for `Empty` and `Struct`'s entries so a schema without
    /// `google/protobuf/*.proto` still handles them.
    func schema(for typeName: String) throws(GRPCCodecError) -> MessageSchema {
        guard let schema = registry.schema(typeName) ?? WellKnownType.supportingSchemas[typeName] else {
            throw GRPCCodecError("`\(typeName)` is not defined in the loaded schema")
        }
        return schema
    }

    func checkDepth(_ depth: Int) throws(GRPCCodecError) {
        guard depth <= Self.maxDepth else {
            throw GRPCCodecError("Messages are nested more than \(Self.maxDepth) levels deep")
        }
    }

    /// Runs `body`, prefixing any error's path with `segment`.
    func within<Result>(
        _ segment: String,
        _ body: () throws(GRPCCodecError) -> Result
    ) throws(GRPCCodecError) -> Result {
        do throws(GRPCCodecError) {
            return try body()
        } catch {
            throw error.prefixed(with: segment)
        }
    }

    static func mismatch(expected: String, got json: ProtoJSONValue) -> GRPCCodecError {
        GRPCCodecError("Expected \(expected), got \(json.typeDescription)")
    }

    /// A map key as a path segment: `counts["en"]`.
    static func keySegment(_ key: String) -> String {
        "[\"\(key)\"]"
    }
}
