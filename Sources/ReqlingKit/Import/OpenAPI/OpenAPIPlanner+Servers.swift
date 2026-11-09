import Foundation
internal import ReqlingYAML

/// Servers as `{{baseUrl}}`: the first server's URL in Default, and with two or more, an environment per server. A
/// server variable (`{region}`) becomes `{{region}}`, its default beside `baseUrl` in each environment, so switching
/// environments switches both. A document with no servers is served from `/`, as OpenAPI says.
extension OpenAPIPlanner {
    struct Server {
        let name: String
        let url: String
        let variables: [Variable]
    }

    mutating func planServers() {
        let servers = servers(root["servers"])
        guard let first = servers.first else {
            return
        }
        addDefaultVariable("baseUrl", value: first.url)
        for variable in first.variables {
            addDefaultVariable(variable.key, value: variable.value)
        }
        guard servers.count > 1 else {
            return
        }
        var names: Set<String> = []
        for server in servers {
            var name = server.name
            if RequestEnvironment.isGlobalName(name) || name.caseInsensitiveCompare(RequestEnvironment.defaultName) == .orderedSame {
                name += " (server)"
            }
            var unique = name
            var suffix = 2
            while names.contains(unique) {
                unique = "\(name) \(suffix)"
                suffix += 1
            }
            names.insert(unique)
            environments.append(RequestEnvironment(name: unique, variables: [Variable(key: "baseUrl", value: server.url)] + server.variables))
        }
        counts.environments = environments.count
    }

    /// A `servers` list's servers, or `/` for none: each URL resolved against a fetched document, trimmed of a trailing
    /// `/`, with `{name}` as `{{name}}`.
    func servers(_ list: OpenAPINode?) -> [Server] {
        let entries = list?.elements ?? []
        guard !entries.isEmpty else {
            return [Server(name: "Server", url: resolvedServerURL("/"), variables: [])]
        }
        return entries.enumerated().map { position, entry in
            let text = entry["url"]?.value.string ?? "/"
            let variables = (entry["variables"]?.members ?? []).map { name, variable in
                Variable(key: name, value: variable["default"]?.value.fieldText ?? "")
            }
            let url = text.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
            return Server(name: serverName(entry, url: text, position: position), url: resolvedServerURL(url), variables: variables)
        }
    }

    /// Notes what a server can't say in a URL: a relative URL in a document read from a file, and a variable's
    /// choices. Run once, over the document's own servers.
    mutating func noteServers() {
        for entry in root["servers"]?.elements ?? [] {
            let text = entry["url"]?.value.string ?? "/"
            if documentBase.isFileURL, !text.contains("://"), !text.hasPrefix("{") {
                note(.environment(RequestEnvironment.defaultName), .url,
                     "The server “\(text)” is relative to wherever the document is served from; put the server's address in baseUrl.")
            }
            for (name, variable) in entry["variables"]?.members ?? [] {
                let choices = (variable["enum"]?.value.array ?? []).map { "“\($0.fieldText)”" }
                if choices.count > 1 {
                    note(.environment(RequestEnvironment.defaultName), .variable, "{{\(name)}} can be \(listed(choices, joiner: "or")).")
                }
            }
        }
    }

    private func serverName(_ entry: OpenAPINode, url: String, position: Int) -> String {
        for candidate in [entry["name"]?.value.string, entry["description"]?.value.string] {
            let line = candidate?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty {
                return line
            }
        }
        if let host = URL(string: url)?.host, !host.contains("{") {
            return host
        }
        return "Server \(position + 1)"
    }

    /// What relative servers resolve against: the document's 3.2 `$self`, or where it was read from.
    private var documentBase: URL {
        OpenAPIReferences.base(of: source.document.root, retrievedFrom: source.document.location)
    }

    /// A relative server URL resolved against the document's base when that's on the web; one in a file stays as
    /// written, noted by `noteServers`. A trailing `/` goes, since paths start with one.
    private func resolvedServerURL(_ text: String) -> String {
        var url = text
        let base = documentBase
        if !base.isFileURL, !text.contains("://"), !text.hasPrefix("{{"),
           let resolved = URL(string: text, relativeTo: base)?.absoluteString {
            url = resolved
        }
        while url.hasSuffix("/") {
            url.removeLast()
        }
        return url
    }

    /// `a`, `a or b`, or `a, b, or c`.
    func listed(_ items: [String], joiner: String = "and") -> String {
        switch items.count {
        case 0, 1: items.joined()
        case 2: items.joined(separator: " \(joiner) ")
        default: items.dropLast().joined(separator: ", ") + ", \(joiner) " + (items.last ?? "")
        }
    }
}
