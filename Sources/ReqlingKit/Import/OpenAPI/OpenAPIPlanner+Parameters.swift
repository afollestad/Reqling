import Foundation
internal import ReqlingYAML

/// Parameters as rows, valued from their examples. Query and header rows are on when required and off otherwise, so
/// they're there to turn on; cookies make one `Cookie` header. `Accept`, `Content-Type`, and `Authorization` header
/// parameters are dropped, as OpenAPI says to: the body, the response, and the auth set those.
extension OpenAPIPlanner {
    struct Parameter {
        let name: String
        let location: String
        let node: OpenAPINode
        var isRequired: Bool {
            node["required"]?.value.bool == true || location == "path"
        }
    }

    /// The path item's parameters, then the operation's, which replace any of the same name and location.
    mutating func parameters(of operation: OpenAPIOperation, owner: ImportNote.Owner) -> [Parameter] {
        var parameters: [Parameter] = []
        let given = (operation.pathItem["parameters"]?.elements ?? []) + (operation.node["parameters"]?.elements ?? [])
        for node in given {
            guard let resolved = resolved(node, owner: owner), let name = resolved["name"]?.value.string,
                  let location = resolved["in"]?.value.string else {
                continue
            }
            let parameter = Parameter(name: name, location: location, node: resolved)
            if let index = parameters.firstIndex(where: { $0.name == name && $0.location == location }) {
                parameters[index] = parameter
            } else {
                parameters.append(parameter)
            }
        }
        return parameters
    }

    mutating func apply(_ parameter: Parameter, to spec: inout HTTPRequestSpec, pathValues: inout [String: String], owner: ImportNote.Owner) {
        if parameter.location == "querystring" {
            let media = parameter.node["content"]?.members.first?.node
            applyQueryString(media.flatMap { mediaExample($0, owner: owner) }, required: parameter.isRequired, to: &spec, owner: owner)
            return
        }
        let value = example(of: parameter.node, owner: owner)
        let style = parameter.node["style"]?.value.string
        let explode = parameter.node["explode"]?.value.bool
        switch parameter.location {
        case "path":
            pathValues[parameter.name] = value.map { Self.simple($0, name: parameter.name, style: style ?? "simple", explode: explode ?? false) }
        case "query":
            let style = style ?? "form"
            spec.queryParameters += Self.queryRows(parameter.name, value: value, style: style, explode: explode ?? (style == "form"))
                .map { KeyValuePair(key: $0.key, value: $0.value, isEnabled: parameter.isRequired) }
        case "header":
            guard !["accept", "content-type", "authorization"].contains(parameter.name.lowercased()) else {
                return
            }
            let text = value.map { Self.simple($0, name: parameter.name, style: "simple", explode: explode ?? false) } ?? ""
            spec.headers.append(KeyValuePair(key: parameter.name, value: text, isEnabled: parameter.isRequired))
        case "cookie":
            addCookie(parameter, value: value, to: &spec)
        default:
            note(owner, .parameter, "Its “\(parameter.name)” parameter is in “\(parameter.location)”, which isn't a place Reqling sends one.")
        }
    }

    /// The parameter's example: its own, then its first named one, then its media type's, then one from its schema.
    mutating func example(of parameter: OpenAPINode, owner: ImportNote.Owner) -> YAMLValue? {
        if let example = parameter["example"] {
            return example.value
        }
        if let first = parameter["examples"]?.members.first, let value = exampleValue(first.node, owner: owner) {
            return value
        }
        if let media = parameter["content"]?.members.first?.node {
            // A parameter given as content is serialized as its media type, JSON in practice.
            return mediaExample(media, owner: owner).map { .string($0.jsonText()) }
        }
        return schemaExample(parameter["schema"], owner: owner)
    }

    private mutating func addCookie(_ parameter: Parameter, value: YAMLValue?, to spec: inout HTTPRequestSpec) {
        let pair = "\(parameter.name)=\(value.map { Self.simple($0, name: parameter.name, style: "form", explode: false) } ?? "")"
        if let index = spec.headers.firstIndex(where: { $0.key == "Cookie" }) {
            spec.headers[index].value += "; \(pair)"
            spec.headers[index].isEnabled = spec.headers[index].isEnabled || parameter.isRequired
        } else {
            spec.headers.append(KeyValuePair(key: "Cookie", value: pair, isEnabled: parameter.isRequired))
        }
    }

    /// OpenAPI 3.2's whole-query parameter: an object's members as rows when it's form-encoded, else a note.
    private mutating func applyQueryString(_ value: YAMLValue?, required: Bool, to spec: inout HTTPRequestSpec, owner: ImportNote.Owner) {
        guard let members = value?.members else {
            note(owner, .parameter, "Its whole query is one parameter Reqling can't split into rows; add the query yourself.")
            return
        }
        spec.queryParameters += members.map { KeyValuePair(key: $0.key, value: $0.value.fieldText, isEnabled: required) }
    }

    // MARK: - Serialization

    /// A path or header value in its style: `simple` (`a,b`), `label` (`.a.b`), or `matrix` (`;id=a,b`).
    static func simple(_ value: YAMLValue, name: String, style: String, explode: Bool) -> String {
        let parts: [String]
        switch value {
        case .array(let items):
            parts = items.map(\.fieldText)
        case .object(let members):
            parts = explode ? members.map { "\($0.key)=\($0.value.fieldText)" } : members.flatMap { [$0.key, $0.value.fieldText] }
        default:
            parts = [value.fieldText]
        }
        switch style {
        case "label":
            return "." + parts.joined(separator: explode ? "." : ",")
        case "matrix":
            return explode && value.array != nil
                ? parts.map { ";\(name)=\($0)" }.joined()
                : ";\(name)=\(parts.joined(separator: ","))"
        default:
            return parts.joined(separator: ",")
        }
    }

    /// A query value's rows in its style: `form` (repeated when exploded), `spaceDelimited`, `pipeDelimited`, or
    /// `deepObject` (`filter[status]`).
    static func queryRows(_ name: String, value: YAMLValue?, style: String, explode: Bool) -> [KeyValuePair] {
        switch value {
        case .array(let items)?:
            if style == "form", explode {
                return items.map { KeyValuePair(key: name, value: $0.fieldText) }
            }
            let separator = style == "spaceDelimited" ? " " : style == "pipeDelimited" ? "|" : ","
            return [KeyValuePair(key: name, value: items.map(\.fieldText).joined(separator: separator))]
        case .object(let members)?:
            if style == "deepObject" {
                return members.map { KeyValuePair(key: "\(name)[\($0.key)]", value: $0.value.fieldText) }
            }
            if explode {
                return members.map { KeyValuePair(key: $0.key, value: $0.value.fieldText) }
            }
            return [KeyValuePair(key: name, value: members.flatMap { [$0.key, $0.value.fieldText] }.joined(separator: ","))]
        default:
            return [KeyValuePair(key: name, value: value?.fieldText ?? "")]
        }
    }
}
