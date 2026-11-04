import SwiftProtobuf

/// A message's fields indexed the ways the codec looks them up: by wire number when decoding, and by JSON or proto
/// name when encoding. The registry builds one per message as it indexes a file, so the codec never rescans
/// descriptors per value.
struct MessageSchema: Sendable {
    let fullName: String
    /// Declaration order, which is also the JSON output order.
    let fields: [FieldSchema]
    private let indexByNumber: [Int32: Int]
    private let indexByName: [String: Int]

    init(fullName: String, fields: [FieldSchema]) {
        self.fullName = fullName
        self.fields = fields
        var byNumber: [Int32: Int] = [:]
        var byName: [String: Int] = [:]
        for (index, field) in fields.enumerated() {
            byNumber[field.number] = index
            byName[field.jsonName] = index
        }
        // Proto names only fill free slots: with `a [json_name = "b"]` and `b`, the key `b` must mean `a`.
        for (index, field) in fields.enumerated() where byName[field.name] == nil {
            byName[field.name] = index
        }
        indexByNumber = byNumber
        indexByName = byName
    }

    init(_ message: Google_Protobuf_DescriptorProto, fullName: String, features: InheritedFeatures) {
        let mapEntries = Set(message.nestedType.filter(\.options.mapEntry).map { "\(fullName).\($0.name)" })
        let fields = message.field.enumerated().map { index, field in
            FieldSchema(
                field,
                index: index,
                features: features,
                mapEntries: mapEntries,
                inMapEntry: message.options.mapEntry
            )
        }
        self.init(fullName: fullName, fields: fields)
    }

    func field(number: Int32) -> FieldSchema? {
        indexByNumber[number].map { fields[$0] }
    }

    /// The field whose JSON name or original proto name is `name`; proto3 JSON parsers must accept both.
    func field(named name: String) -> FieldSchema? {
        indexByName[name].map { fields[$0] }
    }
}

/// One field as the codec sees it, with presence and map-ness resolved from the file's syntax up front.
struct FieldSchema: Sendable {
    typealias Kind = Google_Protobuf_FieldDescriptorProto.TypeEnum

    /// Position in `MessageSchema.fields`, so decoding can collect values in a flat array.
    let index: Int
    let number: Int32
    let name: String
    let jsonName: String
    /// `.message` for proto2 groups too, which differ only in `isDelimited`.
    let kind: Kind
    /// The referenced message or enum, without the leading dot; empty for scalars.
    let typeName: String
    let isRepeated: Bool
    /// A `map<K, V>` field: repeated entries of a synthesized message whose fields 1 and 2 are the key and value.
    let isMap: Bool
    /// Whether a default value is still written and read back as set; proto3 implicit fields are omitted at default.
    let hasPresence: Bool
    /// Members of one oneof share this index, so at most one may be set. proto3 `optional` uses a synthetic oneof.
    let oneofIndex: Int?
    /// A message written between start- and end-group tags rather than length-prefixed: a proto2 group, or an
    /// editions field whose `message_encoding` is `DELIMITED`. A server drops the other form as a wire-type mismatch.
    let isDelimited: Bool

    init(
        index: Int,
        number: Int32,
        name: String,
        kind: Kind,
        typeName: String = "",
        isRepeated: Bool = false,
        isMap: Bool = false,
        hasPresence: Bool = false,
        oneofIndex: Int? = nil,
        isDelimited: Bool = false
    ) {
        self.index = index
        self.number = number
        self.name = name
        jsonName = Self.jsonName(for: name)
        self.kind = kind
        self.typeName = typeName
        self.isRepeated = isRepeated
        self.isMap = isMap
        self.hasPresence = hasPresence
        self.oneofIndex = oneofIndex
        self.isDelimited = isDelimited
    }

    init(
        _ field: Google_Protobuf_FieldDescriptorProto,
        index: Int,
        features: InheritedFeatures,
        mapEntries: Set<String>,
        inMapEntry: Bool
    ) {
        self.index = index
        number = field.number
        name = field.name
        // protoc and reflection servers fill `json_name`; derive it the way protoc does for descriptors that omit it.
        jsonName = field.hasJsonName ? field.jsonName : Self.jsonName(for: field.name)
        kind = field.type == .group ? .message : field.type
        typeName = DescriptorRegistry.normalized(field.typeName)
        isRepeated = field.label == .repeated
        isMap = isRepeated && kind == .message && mapEntries.contains(typeName)
        oneofIndex = field.hasOneofIndex ? Int(field.oneofIndex) : nil
        hasPresence = !isRepeated && (kind == .message || oneofIndex != nil || features.hasExplicitPresence(field))
        // Map entries and their values are always length-prefixed, whatever the inherited encoding says.
        isDelimited = !isMap && !inMapEntry && features.isDelimited(field)
    }

    /// Scalars that repeated fields write packed: everything but strings, bytes, and messages.
    var isPackable: Bool {
        switch kind {
        case .string, .bytes, .message, .group:
            false
        default:
            true
        }
    }

    /// protoc's `ToJsonName`: drop each underscore and uppercase the letter after it.
    static func jsonName(for protoName: String) -> String {
        var result = ""
        var capitalizeNext = false
        for character in protoName {
            if character == "_" {
                capitalizeNext = true
            } else if capitalizeNext {
                result += character.uppercased()
                capitalizeNext = false
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// What a file's syntax and editions features decide about its fields, as each message inherits it. Editions
/// features resolve from the field, then its enclosing messages, then the file.
///
/// - Presence: proto2 `optional` and `required` fields track it, proto3 fields only through `optional` (a synthetic
///   oneof), and editions fields unless `field_presence` is `IMPLICIT`.
/// - Delimited encoding: proto2 groups, and editions message fields whose `message_encoding` is `DELIMITED`.
struct InheritedFeatures: Sendable {
    private let syntax: Syntax
    private let presence: Google_Protobuf_FeatureSet.FieldPresence
    private let messageEncoding: Google_Protobuf_FeatureSet.MessageEncoding

    private enum Syntax: Sendable {
        case proto2
        case proto3
        case editions
    }

    init(file: Google_Protobuf_FileDescriptorProto) {
        let syntax: Syntax = switch file.syntax {
        case "proto3":
            .proto3
        case "editions":
            .editions
        default:
            .proto2
        }
        // Edition 2023's defaults.
        self.init(syntax: syntax, features: file.options.features, presence: .explicit, messageEncoding: .lengthPrefixed)
    }

    private init(
        syntax: Syntax,
        features: Google_Protobuf_FeatureSet,
        presence: Google_Protobuf_FeatureSet.FieldPresence,
        messageEncoding: Google_Protobuf_FeatureSet.MessageEncoding
    ) {
        self.syntax = syntax
        self.presence = features.hasFieldPresence ? features.fieldPresence : presence
        self.messageEncoding = features.hasMessageEncoding ? features.messageEncoding : messageEncoding
    }

    /// The features a message's fields and nested types inherit.
    func nested(in message: Google_Protobuf_DescriptorProto) -> InheritedFeatures {
        InheritedFeatures(syntax: syntax, features: message.options.features, presence: presence, messageEncoding: messageEncoding)
    }

    func hasExplicitPresence(_ field: Google_Protobuf_FieldDescriptorProto) -> Bool {
        switch syntax {
        case .proto2:
            return field.label != .repeated
        case .proto3:
            return false
        case .editions:
            let features = field.options.features
            return (features.hasFieldPresence ? features.fieldPresence : presence) != .implicit
        }
    }

    func isDelimited(_ field: Google_Protobuf_FieldDescriptorProto) -> Bool {
        if field.type == .group {
            return true
        }
        guard syntax == .editions, field.type == .message else {
            return false
        }
        let features = field.options.features
        return (features.hasMessageEncoding ? features.messageEncoding : messageEncoding) == .delimited
    }
}
