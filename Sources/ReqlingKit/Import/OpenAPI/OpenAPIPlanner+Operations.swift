import Foundation
import ReqlingScriptProtocol
internal import ReqlingYAML

/// An operation as a request: named by its summary, sent to `{{baseUrl}}` and its path, with its parameters, example
/// body, and auth.
extension OpenAPIPlanner {
    mutating func request(for operation: OpenAPIOperation, in folder: [String]) -> OpenAPIPlannedRequest {
        let name = Self.requestName(operation)
        let owner = ImportNote.Owner.node(folder + [name])
        counts.requests += 1
        if operation.node["deprecated"]?.value.bool == true {
            deprecated.append(name)
        }
        var spec = HTTPRequestSpec(method: operation.method)
        let (path, inSegment) = Self.path(operation.path)
        spec.url = serverPrefix(of: operation, owner: owner) + path
        var pathValues: [String: String] = [:]
        for parameter in parameters(of: operation, owner: owner) {
            apply(parameter, to: &spec, pathValues: &pathValues, owner: owner)
        }
        for name in inSegment {
            addDefaultVariable(name, value: pathValues[name] ?? "")
            note(.project, .url, "A path puts {\(name)} inside a segment, where a path variable can't go, so it's {{\(name)}} in Default.")
        }
        spec = spec.normalized()
        for index in spec.pathVariables.indices {
            spec.pathVariables[index].value = pathValues[spec.pathVariables[index].key] ?? ""
        }
        body(of: operation, into: &spec, owner: owner)
        let auth = auth(for: operation.node["security"] ?? root["security"], owner: owner)
        spec.headers += auth.headers
        spec.queryParameters += auth.query
        return OpenAPIPlannedRequest(item: RequestItem(name: name, kind: .http(spec)), auth: auth.auth)
    }

    /// The first line of its summary, else its `operationId`, else its method and path.
    static func requestName(_ operation: OpenAPIOperation) -> String {
        for candidate in [operation.node["summary"]?.value.string, operation.node["operationId"]?.value.string] {
            let line = candidate?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty {
                return line
            }
        }
        return "\(operation.method.rawValue) \(operation.path)"
    }

    /// The path with each whole `{name}` segment as a `:name` path variable, and any other `{name}` as `{{name}}`, with
    /// those names; Reqling's path variables are whole segments, so `/files/{name}.{ext}` keeps its variables in Default.
    static func path(_ path: String) -> (String, [String]) {
        var inSegment: [String] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            if segment.hasPrefix("{"), segment.hasSuffix("}"), segment.count > 2 {
                let name = segment.dropFirst().dropLast()
                if !name.contains("{"), !name.contains("}"), RequestPathVariables.isValidName(name) {
                    return ":\(name)"
                }
            }
            // One pass, so the braces it writes are never read again.
            var text = ""
            var rest = segment[...]
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                let name = String(rest[rest.index(after: open)..<close])
                if !inSegment.contains(name) {
                    inSegment.append(name)
                }
                text += rest[..<open] + "{{\(name)}}"
                rest = rest[rest.index(after: close)...]
            }
            return text + rest
        }
        let joined = segments.joined(separator: "/")
        return (joined.hasPrefix("/") || joined.isEmpty ? joined : "/\(joined)", inSegment)
    }

    /// `{{baseUrl}}`, unless the operation or its path names servers of its own whose first differs from the
    /// document's; then that server's URL, with a note naming any others.
    private mutating func serverPrefix(of operation: OpenAPIOperation, owner: ImportNote.Owner) -> String {
        guard let list = operation.node["servers"] ?? operation.pathItem["servers"], !(list.value.array ?? []).isEmpty else {
            return "{{baseUrl}}"
        }
        let own = servers(list)
        let documentFirst = servers(root["servers"]).first?.url
        guard let first = own.first, first.url != documentFirst else {
            return "{{baseUrl}}"
        }
        for variable in first.variables {
            addDefaultVariable(variable.key, value: variable.value)
        }
        let others = own.dropFirst().map { "“\($0.url)”" }
        let alternatives = others.isEmpty ? "" : " It can also use \(listed(Array(others), joiner: "or"))."
        note(owner, .url, "It's sent to its own server, “\(first.url)”, rather than {{baseUrl}}.\(alternatives)")
        return first.url
    }
}
