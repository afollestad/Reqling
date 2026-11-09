import Foundation
import ReqlingTemplating

/// Literal passwords, tokens, and API keys from imported auth, each moved into a secret variable in the project's
/// Default environment, so the project's files carry `{{bearerToken}}` and the Keychain the value. Equal values of one
/// kind share a variable; distinct ones are numbered (`bearerToken2`). A name already in use (a source's variable, or
/// one a script sets) is skipped, since an active environment's would override Default's.
struct ImportCredentials {
    enum Kind: String {
        case basicPassword
        case bearerToken
        case apiKey
    }

    private var reserved: Set<String>
    private var names: [Kind: [String: String]] = [:]
    /// `placeholder`'s names, by scheme and part.
    private var placeholders: [String: String] = [:]
    private(set) var variables: [Variable] = []

    init(reserved: Set<String>) {
        self.reserved = reserved
    }

    /// Keeps `name` from being given to a credential, for a variable the import makes itself.
    mutating func reserve(_ name: String) {
        reserved.insert(name)
    }

    /// A reference to an empty variable for the person to fill in, for a credential a source only describes, as an
    /// OpenAPI security scheme does: one per scheme and part (`bearerToken` for a scheme's token, `username` and
    /// `password` for its basic credentials), numbered past names in use like `reference`'s.
    mutating func placeholder(_ base: String, for scheme: String, isSecret: Bool = true) -> String {
        let key = "\(scheme)\u{0}\(base)"
        if let name = placeholders[key] {
            return "{{\(name)}}"
        }
        let name = available(base)
        placeholders[key] = name
        variables.append(Variable(key: name, value: "", isSecret: isSecret))
        return "{{\(name)}}"
    }

    /// What the auth keeps for `value`: a reference to the secret variable holding it, or the value itself when it's
    /// empty or already uses a variable.
    mutating func reference(for value: String, kind: Kind) -> String {
        guard !value.isEmpty, TemplateParser.tokens(in: value).isEmpty else {
            return value
        }
        if let name = names[kind]?[value] {
            return "{{\(name)}}"
        }
        let name = available(kind.rawValue)
        names[kind, default: [:]][value] = name
        variables.append(Variable(key: name, value: value, isSecret: true))
        return "{{\(name)}}"
    }

    /// `base`, or `base2`, `base3`, and so on past every name in use; reserved once returned.
    private mutating func available(_ base: String) -> String {
        var name = base
        var suffix = 2
        while reserved.contains(name) {
            name = "\(base)\(suffix)"
            suffix += 1
        }
        reserved.insert(name)
        return name
    }
}
