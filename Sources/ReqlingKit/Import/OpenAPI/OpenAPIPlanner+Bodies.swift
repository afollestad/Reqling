import Foundation
internal import ReqlingYAML

/// A request body as Reqling's: of the media types an operation accepts, JSON first, then forms, YAML, XML, text, and
/// anything else as a binary body, with an example from the document or made from its schema.
extension OpenAPIPlanner {
    enum MediaKind: Int, Comparable {
        case jsonExact, json, form, multipart, yaml, xml, text, binary

        init(_ mediaType: String) {
            let base = mediaType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            self = switch base {
            case "application/json": .jsonExact
            case _ where base.hasSuffix("+json") || base.hasSuffix("/json"): .json
            case "application/x-www-form-urlencoded": .form
            case _ where base.hasPrefix("multipart/"): .multipart
            case _ where base.hasSuffix("+yaml") || base.hasSuffix("/yaml") || base.hasSuffix("/x-yaml"): .yaml
            case _ where base.hasSuffix("+xml") || base.hasSuffix("/xml"): .xml
            case _ where base.hasPrefix("text/"): .text
            default: .binary
            }
        }

        static func < (lhs: MediaKind, rhs: MediaKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    mutating func body(of operation: OpenAPIOperation, into spec: inout HTTPRequestSpec, owner: ImportNote.Owner) {
        guard let requestBody = resolved(operation.node["requestBody"], owner: owner) else {
            return
        }
        let content = requestBody["content"]?.members ?? []
        guard let chosen = content.enumerated().min(by: { (MediaKind($0.element.key), $0.offset) < (MediaKind($1.element.key), $1.offset) })?
            .element else {
            return
        }
        let (mediaType, media) = chosen
        switch MediaKind(mediaType) {
        case .jsonExact, .json:
            let text = mediaExample(media, owner: owner).map { JSONFormatter.pretty($0.jsonText()) ?? $0.jsonText() } ?? ""
            spec.body = HTTPBody(mode: .raw, raw: RawBody(text: text, contentType: mediaType))
        case .yaml:
            spec.body = HTTPBody(mode: .raw, raw: RawBody(text: mediaExample(media, owner: owner)?.yamlText() ?? "", contentType: mediaType))
        case .form:
            spec.body = HTTPBody(mode: .urlEncoded, urlEncoded: formRows(media, owner: owner))
        case .multipart:
            spec.body = HTTPBody(mode: .formData, formData: multipartFields(media, owner: owner))
        case .xml:
            spec.body = HTTPBody(mode: .raw, raw: RawBody(text: xmlExample(media, owner: owner), contentType: mediaType))
        case .text:
            spec.body = HTTPBody(mode: .raw, raw: RawBody(text: mediaExample(media, owner: owner)?.fieldText ?? "", contentType: mediaType))
        case .binary:
            let contentType = mediaType.contains("*") ? nil : mediaType
            spec.body = HTTPBody(mode: .binary, binary: BinaryBody(contentType: contentType))
            note(owner, .file, "Choose its body's file (\(mediaType)).")
        }
        if !spec.method.bodyPolicy.allowsBody {
            note(owner, .body, "The document gives it a body, which a \(spec.method.rawValue) never sends; it's kept for another method.")
        }
    }

    /// A media type's example: its own, then its first named one, then one made from its schema.
    mutating func mediaExample(_ media: OpenAPINode, owner: ImportNote.Owner) -> YAMLValue? {
        if let example = media["example"] {
            return example.value
        }
        if let first = media["examples"]?.members.first, let value = exampleValue(first.node, owner: owner) {
            return value
        }
        return schemaExample(media["schema"] ?? media["itemSchema"], owner: owner)
    }

    /// An Example object's value: 3.2's `dataValue`, its `value`, its `serializedValue` as text, or the text its
    /// `externalValue` was loaded as.
    mutating func exampleValue(_ example: OpenAPINode, owner: ImportNote.Owner) -> YAMLValue? {
        guard let example = resolved(example, owner: owner) else {
            return nil
        }
        if let value = example["dataValue"] ?? example["value"] {
            return value.value
        }
        if let serialized = example["serializedValue"]?.value.string {
            return .string(serialized)
        }
        guard let external = example["externalValue"]?.value.string, let document = source.documents[example.document] else {
            return nil
        }
        let base = OpenAPIReferences.base(of: document, retrievedFrom: example.document)
        guard let url = URL(string: external, relativeTo: base)?.absoluteURL else {
            return nil
        }
        guard let text = source.externalValues[url] else {
            note(owner, .reference, "Its example at “\(external)” couldn't be loaded. \(source.failures[url] ?? "")")
            return nil
        }
        return (try? StructuredText.parse(Data(text.utf8))) ?? .string(text)
    }

    /// XML only from an example the document writes out; one made from a schema would guess at its elements.
    private mutating func xmlExample(_ media: OpenAPINode, owner: ImportNote.Owner) -> String {
        let given = media["example"]?.value ?? media["examples"]?.members.first.flatMap { exampleValue($0.node, owner: owner) }
        if case .string(let text)? = given {
            return text
        }
        note(owner, .body, "Its XML body has no written-out example, so it's empty; write one.")
        return ""
    }

    /// A form's fields from its example, each on when the schema requires it, or when it requires none.
    private mutating func formRows(_ media: OpenAPINode, owner: ImportNote.Owner) -> [KeyValuePair] {
        let required = requiredProperties(media["schema"], owner: owner)
        return (mediaExample(media, owner: owner)?.members ?? []).map { member in
            KeyValuePair(key: member.key, value: member.value.fieldText, isEnabled: required.isEmpty || required.contains(member.key))
        }
    }

    /// Multipart parts: a file part, left to choose, for each binary property, and text for the rest, with the content
    /// types its `encoding` gives.
    private mutating func multipartFields(_ media: OpenAPINode, owner: ImportNote.Owner) -> [MultipartField] {
        let required = requiredProperties(media["schema"], owner: owner)
        let example = mediaExample(media, owner: owner)?.members ?? []
        let properties = objectProperties(media["schema"], owner: owner)
        return example.map { member in
            let contentType = media["encoding"]?[member.key]?["contentType"]?.value.string
            let isEnabled = required.isEmpty || required.contains(member.key)
            guard let schema = properties.first(where: { $0.name == member.key })?.schema, isBinary(schema) else {
                return MultipartField(key: member.key, kind: .text, value: member.value.fieldText, contentType: contentType, isEnabled: isEnabled)
            }
            note(owner, .file, "Choose the file for “\(member.key)”.")
            return MultipartField(key: member.key, kind: .file, contentType: contentType, isEnabled: isEnabled)
        }
    }

    private func isBinary(_ schema: OpenAPINode) -> Bool {
        let schema = resolver.resolveOrNil(schema) ?? schema
        if ["binary", "byte"].contains(schema["format"]?.value.string ?? "") {
            return true
        }
        guard let mediaType = schema["contentMediaType"]?.value.string else {
            return false
        }
        return !mediaType.hasPrefix("text/") && MediaKind(mediaType) == .binary
    }
}
