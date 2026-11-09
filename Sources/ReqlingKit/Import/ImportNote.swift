import Foundation
import ReqlingScriptProtocol

/// Something an import couldn't carry over as it was, for the person to look at; an importer notes it rather than
/// dropping it silently.
public struct ImportNote: Hashable, Sendable {
    public enum Owner: Hashable, Sendable {
        case project
        /// A folder or request, by the names of its folders and its own.
        case node([String])
        case environment(String)
    }

    public enum Topic: Hashable, Sendable {
        /// A script problem, by its phase and, when it has one, the line it's on.
        case script(ScriptPhase, line: Int?)
        case auth
        case body
        case file
        case variable
        case url
        case parameter
        /// A `$ref` that couldn't be followed.
        case reference
        case operation
    }

    public let owner: Owner
    public let topic: Topic
    public let message: String
}

/// What an import brought over, for its summary.
public struct ImportCounts: Hashable, Sendable {
    public var requests = 0
    public var folders = 0
    public var environments = 0
    /// Literal credentials moved into secret variables, by variable name.
    public var credentials: [String] = []
    /// Empty secret variables made for credentials the source only describes, by name, for the person to fill in.
    public var credentialsToFill: [String] = []
    /// What the source held that Reqling has nowhere to keep, by kind; a kind it held none of is absent.
    public var omitted: [ImportOmission: Int] = [:]
}

/// A kind of thing an import leaves out, counted rather than noted one by one; a summary lists them in case order.
public enum ImportOmission: Hashable, Sendable, CaseIterable {
    case descriptions
    /// Example responses saved with requests.
    case savedResponses
    /// An API description's responses, each status's.
    case responses
    case callbacks
    case links
    case webhooks
}

/// What an import added to or changed in one environment, by key.
public struct ImportEnvironmentChange: Hashable, Sendable {
    public let environment: String
    public let isNew: Bool
    public let added: [String]
    public let updated: [String]
}

/// A body file a request names, found on this Mac at `url`, for the request's binary body or one form part.
struct ImportFileSlot: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case binary
        case formField(MultipartFieldID)
    }

    let request: RequestNodeID
    let target: Target
    let url: URL

    /// Where the project holds the file, which a this-Mac-only one is chosen for.
    var pathSlot: ProjectPathSlot {
        switch target {
        case .binary: .binaryBody(request)
        case .formField(let field): .formField(request, field)
        }
    }
}
