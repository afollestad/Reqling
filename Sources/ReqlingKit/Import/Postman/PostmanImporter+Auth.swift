import Foundation

/// Postman's auth as Reqling's: basic, bearer, and API key carry over, with literal credentials moved into secret
/// variables (`ImportCredentials`); no auth stays none; a type Reqling doesn't have becomes none, with a note.
extension PostmanPlanner {
    /// `inheritedByDefault` is false for the collection, whose missing auth means none, as a project's does.
    mutating func auth(_ auth: PostmanJSON?, owner: ImportNote.Owner, inheritedByDefault: Bool) -> HTTPAuth {
        let unset: HTTPAuth = inheritedByDefault ? .inherit : .none
        guard let auth, let type = auth["type"]?.string else {
            return unset
        }
        // v2.1 lists a type's attributes as `[{ key, value }]`; v2.0 as one object.
        func attribute(_ key: String) -> String {
            let section = auth[type]
            if let list = section?.array {
                return list.last { $0["key"]?.string == key }?["value"]?.text ?? ""
            }
            return section?[key]?.text ?? ""
        }
        switch type {
        case "noauth":
            return .none
        case "inherit":
            return unset
        case "basic":
            return .basic(username: attribute("username"), password: credentials.reference(for: attribute("password"), kind: .basicPassword))
        case "bearer":
            return .bearer(token: credentials.reference(for: attribute("token"), kind: .bearerToken))
        case "apikey":
            let location: HTTPAuth.APIKeyLocation = attribute("in") == "query" ? .query : .header
            return .apiKey(name: attribute("key"), value: credentials.reference(for: attribute("value"), kind: .apiKey), location: location)
        default:
            note(owner, .auth, "It used \(Self.authName(type)) auth, which Reqling doesn't have, so it has none; set it up yourself.")
            // None rather than inherited, so a parent's other auth isn't sent in its place.
            return .none
        }
    }

    private static func authName(_ type: String) -> String {
        switch type {
        case "oauth2": "OAuth 2.0"
        case "oauth1": "OAuth 1.0"
        case "digest": "Digest"
        case "awsv4": "AWS Signature"
        case "hawk": "Hawk"
        case "ntlm": "NTLM"
        case "edgegrid": "Akamai EdgeGrid"
        case "jwt": "JWT Bearer"
        case "asap": "ASAP"
        default: "“\(type)”"
        }
    }
}
