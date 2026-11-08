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
    private(set) var variables: [Variable] = []

    init(reserved: Set<String>) {
        self.reserved = reserved
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
        var name = kind.rawValue
        var suffix = 2
        while reserved.contains(name) {
            name = "\(kind.rawValue)\(suffix)"
            suffix += 1
        }
        reserved.insert(name)
        names[kind, default: [:]][value] = name
        variables.append(Variable(key: name, value: value, isSecret: true))
        return "{{\(name)}}"
    }
}
