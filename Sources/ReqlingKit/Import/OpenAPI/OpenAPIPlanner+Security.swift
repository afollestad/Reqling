import Foundation
internal import ReqlingYAML

/// What a security scheme maps to: auth a request sends, nothing to send (a client certificate, which the project's
/// TLS settings hold), or nothing Reqling has, noted when the scheme is first used.
enum OpenAPISchemeAuth: Hashable {
    case auth(HTTPAuth)
    case satisfied
    case unsupported
}

/// The auth an operation's security requirement maps to, and any further API keys it also needs, sent as rows.
struct OpenAPIOperationAuth {
    var auth: HTTPAuth = .none
    var headers: [KeyValuePair] = []
    var query: [KeyValuePair] = []
}

/// Security schemes as auth. Basic, bearer, and API keys in a header or the query map directly, OAuth 2.0 and OpenID
/// Connect to bearer auth with the token left to get, each with empty variables in Default for the person to fill in;
/// only schemes some request uses make them.
extension OpenAPIPlanner {
    /// The first requirement in `requirements` (an operation's `security`, else the document's) that Reqling can meet:
    /// its first scheme as the auth and any other API keys as rows. `[]`, or `{}` reached first, means none.
    mutating func auth(for requirements: OpenAPINode?, owner: ImportNote.Owner) -> OpenAPIOperationAuth {
        guard let list = requirements?.value.array, !list.isEmpty else {
            return OpenAPIOperationAuth()
        }
        for requirement in list {
            let names = requirement.members?.map(\.key) ?? []
            guard !names.isEmpty else {
                return OpenAPIOperationAuth()
            }
            let mapped = names.map { (name: $0, auth: schemeAuth($0)) }
            guard !mapped.contains(where: { $0.auth == .unsupported }) else {
                continue
            }
            return combined(mapped, owner: owner)
        }
        note(owner, .auth, "None of its security requirements can be met with Reqling's auth, so it has none.")
        return OpenAPIOperationAuth()
    }

    private mutating func combined(_ mapped: [(name: String, auth: OpenAPISchemeAuth)], owner: ImportNote.Owner) -> OpenAPIOperationAuth {
        var result = OpenAPIOperationAuth()
        var primary: HTTPAuth?
        for (name, scheme) in mapped {
            guard case .auth(let auth) = scheme else {
                continue
            }
            guard primary != nil else {
                primary = auth
                continue
            }
            switch auth {
            case .apiKey(let key, let value, .header):
                result.headers.append(KeyValuePair(key: key, value: value))
            case .apiKey(let key, let value, .query):
                result.query.append(KeyValuePair(key: key, value: value))
            default:
                note(owner, .auth, "It also needs the “\(name)” scheme, but a request sends one auth; add that one's yourself.")
            }
        }
        result.auth = primary ?? .none
        return result
    }

    private mutating func schemeAuth(_ name: String) -> OpenAPISchemeAuth {
        if let known = schemes[name] {
            return known
        }
        let mapped = mapScheme(name)
        schemes[name] = mapped
        return mapped
    }

    private mutating func mapScheme(_ name: String) -> OpenAPISchemeAuth {
        guard let scheme = resolved(root["components"]?["securitySchemes"]?[name], owner: .project) else {
            note(.project, .auth, "The security scheme “\(name)” isn't defined, so it gives requests no auth.")
            return .unsupported
        }
        switch scheme["type"]?.value.string ?? "" {
        case "http":
            return httpScheme(name, scheme: scheme)
        case "apiKey":
            return apiKeyScheme(name, scheme: scheme)
        case "oauth2", "openIdConnect":
            let token = credentials.placeholder("accessToken", for: name)
            note(.project, .auth, tokenMessage(name, scheme: scheme, token: token))
            return .auth(.bearer(token: token))
        case "mutualTLS":
            note(.project, .auth, "The “\(name)” scheme asks for a client certificate; add one in the project's TLS settings.")
            return .satisfied
        case let type:
            note(.project, .auth, "The “\(name)” scheme is “\(type)”, which Reqling doesn't have, so it gives requests no auth.")
            return .unsupported
        }
    }

    private mutating func httpScheme(_ name: String, scheme: OpenAPINode) -> OpenAPISchemeAuth {
        switch (scheme["scheme"]?.value.string ?? "").lowercased() {
        case "basic":
            let username = credentials.placeholder("username", for: name, isSecret: false)
            return .auth(.basic(username: username, password: credentials.placeholder("password", for: name)))
        case "bearer":
            return .auth(.bearer(token: credentials.placeholder("bearerToken", for: name)))
        case let other:
            note(.project, .auth, "The “\(name)” scheme uses HTTP \(other) auth, which Reqling doesn't have, so it gives requests no auth.")
            return .unsupported
        }
    }

    private mutating func apiKeyScheme(_ name: String, scheme: OpenAPINode) -> OpenAPISchemeAuth {
        let key = scheme["name"]?.value.string ?? name
        switch scheme["in"]?.value.string {
        case "header":
            return .auth(.apiKey(name: key, value: credentials.placeholder("apiKey", for: name), location: .header))
        case "query":
            return .auth(.apiKey(name: key, value: credentials.placeholder("apiKey", for: name), location: .query))
        default:
            note(.project, .auth, "The “\(name)” scheme sends its key in the “\(key)” cookie, which auth can't; add a Cookie header instead.")
            return .unsupported
        }
    }

    /// Where an OAuth 2.0 or OpenID Connect scheme's token comes from, since Reqling doesn't run the flow itself.
    private func tokenMessage(_ name: String, scheme: OpenAPINode, token: String) -> String {
        if let discovery = scheme["openIdConnectUrl"]?.value.string {
            return "The “\(name)” scheme uses OpenID Connect (\(discovery)), which Reqling doesn't run; put a token in \(token)."
        }
        let flows = scheme["flows"]?.members ?? []
        let tokenURL = flows.lazy.compactMap { $0.node["tokenUrl"]?.value.string }.first
        let flowNames = flows.map { Self.flowName($0.key) }
        let uses = flowNames.isEmpty ? "OAuth 2.0" : "OAuth 2.0 (\(listed(flowNames, joiner: "or")))"
        let from = tokenURL.map { " from \($0)" } ?? ""
        return "The “\(name)” scheme uses \(uses), which Reqling doesn't run; get a token\(from) and put it in \(token)."
    }

    private static func flowName(_ key: String) -> String {
        switch key {
        case "authorizationCode": "authorization code"
        case "clientCredentials": "client credentials"
        case "deviceAuthorization": "device authorization"
        default: key
        }
    }

    /// The project takes the document's own security, or the one auth every request shares; a folder takes the auth
    /// every request beneath it shares where that differs from what it would inherit; a request whose auth is what it
    /// would inherit inherits it. Returns the project's.
    mutating func placeAuth(in tree: inout OpenAPIFolderTree) -> HTTPAuth {
        let shared = Set(tree.auths)
        let projectAuth = root["security"] != nil
            ? auth(for: root["security"], owner: .project).auth
            : (shared.count == 1 ? shared.first ?? .none : .none)
        tree.place(inherited: projectAuth)
        return projectAuth
    }
}

extension OpenAPIFolderTree {
    /// Every request's auth beneath this folder.
    var auths: [HTTPAuth] {
        requests.map(\.auth) + folders.flatMap(\.auths)
    }

    mutating func place(inherited: HTTPAuth) {
        for index in folders.indices {
            let shared = Set(folders[index].auths)
            var effective = inherited
            if shared.count == 1, let only = shared.first, only != inherited {
                folders[index].auth = only
                effective = only
            }
            folders[index].place(inherited: effective)
        }
        for index in requests.indices {
            guard case .http(var spec) = requests[index].item.kind else {
                continue
            }
            spec.auth = requests[index].auth == inherited ? .inherit : requests[index].auth
            requests[index].item.kind = .http(spec)
        }
    }
}
