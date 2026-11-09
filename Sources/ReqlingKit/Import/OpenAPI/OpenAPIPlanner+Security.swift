import Foundation
internal import ReqlingYAML

/// A security scheme Reqling can meet, as the document defines it. Finding one makes nothing; its variables and notes
/// wait until a request uses it (`OpenAPIPlanner.schemeAuth`), so an alternative passed over leaves none behind.
struct OpenAPIScheme {
    enum Kind {
        case basic
        case bearer
        case apiKey(name: String, location: HTTPAuth.APIKeyLocation)
        /// OAuth 2.0 or OpenID Connect, whose token the person gets themselves.
        case token
        /// mutualTLS, met by a client certificate in the project's TLS settings rather than by auth.
        case clientCertificate
    }

    let kind: Kind
    let node: OpenAPINode
    /// 3.2's `deprecated`; an alternative without one is chosen first.
    let isDeprecated: Bool
}

/// What a scheme a request uses maps to: auth it sends, or nothing to send (a client certificate).
enum OpenAPISchemeAuth: Hashable {
    case auth(HTTPAuth)
    case satisfied
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
    /// The requirement in `requirements` (an operation's `security`, else the document's) to use: the first Reqling can
    /// meet without a deprecated scheme, else the first it can meet at all. Its first scheme is the auth, and any other
    /// API keys are rows. `[]`, or `{}` chosen, means none. Requirements after the first met without a deprecated scheme
    /// go unread, so their schemes make no notes.
    mutating func auth(for requirements: OpenAPINode?, owner: ImportNote.Owner) -> OpenAPIOperationAuth {
        guard let list = requirements?.value.array, !list.isEmpty else {
            return OpenAPIOperationAuth()
        }
        var chosen: [(name: String, scheme: OpenAPIScheme)]?
        var fallback: [(name: String, scheme: OpenAPIScheme)]?
        for requirement in list {
            let names = requirement.members?.map(\.key) ?? []
            let found = names.compactMap { name in scheme(name).map { (name: name, scheme: $0) } }
            guard found.count == names.count else {
                continue
            }
            guard found.contains(where: \.scheme.isDeprecated) else {
                chosen = found
                break
            }
            fallback = fallback ?? found
        }
        guard let chosen = chosen ?? fallback else {
            note(owner, .auth, "None of its security requirements can be met with Reqling's auth, so it has none.")
            return OpenAPIOperationAuth()
        }
        return combined(chosen.map { (name: $0.name, auth: schemeAuth($0.name, $0.scheme)) }, owner: owner)
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

    /// The scheme `name` defines, or `nil`, noted once, for one Reqling can't meet.
    private mutating func scheme(_ name: String) -> OpenAPIScheme? {
        if let known = schemes[name] {
            return known
        }
        let found = findScheme(name)
        schemes.updateValue(found, forKey: name)
        return found
    }

    private mutating func findScheme(_ name: String) -> OpenAPIScheme? {
        guard let node = resolved(root["components"]?["securitySchemes"]?[name], owner: .project) else {
            note(.project, .auth, "The security scheme “\(name)” isn't defined, so it gives requests no auth.")
            return nil
        }
        let kind: OpenAPIScheme.Kind
        switch node["type"]?.value.string ?? "" {
        case "http":
            guard let http = httpKind(name, scheme: node) else {
                return nil
            }
            kind = http
        case "apiKey":
            guard let apiKey = apiKeyKind(name, scheme: node) else {
                return nil
            }
            kind = apiKey
        case "oauth2", "openIdConnect":
            kind = .token
        case "mutualTLS":
            kind = .clientCertificate
        case let type:
            note(.project, .auth, "The “\(name)” scheme is “\(type)”, which Reqling doesn't have, so it gives requests no auth.")
            return nil
        }
        return OpenAPIScheme(kind: kind, node: node, isDeprecated: node["deprecated"]?.value.bool == true)
    }

    /// What `scheme` maps to, with its variables and notes made the first time a request uses it.
    private mutating func schemeAuth(_ name: String, _ scheme: OpenAPIScheme) -> OpenAPISchemeAuth {
        if let known = schemeAuths[name] {
            return known
        }
        let mapped: OpenAPISchemeAuth
        switch scheme.kind {
        case .basic:
            let username = credentials.placeholder("username", for: name, isSecret: false)
            mapped = .auth(.basic(username: username, password: credentials.placeholder("password", for: name)))
        case .bearer:
            mapped = .auth(.bearer(token: credentials.placeholder("bearerToken", for: name)))
        case .apiKey(let key, let location):
            mapped = .auth(.apiKey(name: key, value: credentials.placeholder("apiKey", for: name), location: location))
        case .token:
            let token = credentials.placeholder("accessToken", for: name)
            note(.project, .auth, tokenMessage(name, scheme: scheme.node, token: token))
            mapped = .auth(.bearer(token: token))
        case .clientCertificate:
            note(.project, .auth, "The “\(name)” scheme asks for a client certificate; add one in the project's TLS settings.")
            mapped = .satisfied
        }
        schemeAuths[name] = mapped
        return mapped
    }

    private mutating func httpKind(_ name: String, scheme: OpenAPINode) -> OpenAPIScheme.Kind? {
        switch (scheme["scheme"]?.value.string ?? "").lowercased() {
        case "basic":
            return .basic
        case "bearer":
            return .bearer
        case let other:
            note(.project, .auth, "The “\(name)” scheme uses HTTP \(other) auth, which Reqling doesn't have, so it gives requests no auth.")
            return nil
        }
    }

    private mutating func apiKeyKind(_ name: String, scheme: OpenAPINode) -> OpenAPIScheme.Kind? {
        let key = scheme["name"]?.value.string ?? name
        switch scheme["in"]?.value.string {
        case "header":
            return .apiKey(name: key, location: .header)
        case "query":
            return .apiKey(name: key, location: .query)
        default:
            note(.project, .auth, "The “\(name)” scheme sends its key in the “\(key)” cookie, which auth can't; add a Cookie header instead.")
            return nil
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
