import Foundation
import ReqlingScriptProtocol

/// A Postman collection, with its environments and globals, mapped to Reqling's model by `PostmanImporter.plan` and
/// ready for `ProjectLifecycle.importPostman` to write as a new project. Every ID in it is fresh.
public struct PostmanImport: Sendable {
    /// The collection's name, which the project takes unless the person gives another.
    public let name: String
    let auth: HTTPAuth
    let scripts: ScriptSet
    let items: [RequestNode]
    /// The collection's variables and the literal credentials moved out of its auth, then any "Default" environment's.
    let defaultVariables: [Variable]
    let environments: [RequestEnvironment]
    /// The globals files' variables, merged into the library's Global when the project is written.
    let globals: [Variable]
    /// Body files found on this Mac, pointed at once the project's folder is known.
    let files: [PostmanFileSlot]
    public let notes: [PostmanImportNote]
    public let counts: PostmanImportCounts
    /// The environments the import adds or changes, by name, Default included; Global's is reported when it's written.
    public let environmentChanges: [PostmanEnvironmentChange]
    /// Whether any script came along, which decides whether the new project's scripts are trusted.
    public let hasScripts: Bool
}

/// Something the import couldn't carry over as it was, for the person to look at.
public struct PostmanImportNote: Hashable, Sendable {
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
        case url
        case body
        case file
        case variable
    }

    public let owner: Owner
    public let topic: Topic
    public let message: String
}

public struct PostmanImportCounts: Hashable, Sendable {
    public var requests = 0
    public var folders = 0
    public var environments = 0
    /// Postman's descriptions, which Reqling has nowhere to keep.
    public var descriptions = 0
    /// Example responses saved with requests.
    public var savedResponses = 0
    /// Literal credentials moved into secret variables, by variable name.
    public var credentials: [String] = []
}

/// What an import added to or changed in one environment, by key.
public struct PostmanEnvironmentChange: Hashable, Sendable {
    public let environment: String
    public let isNew: Bool
    public let added: [String]
    public let updated: [String]
}

/// A body file a request's Postman `src` names, found at `url`, for the request's binary body or one form part.
struct PostmanFileSlot: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case binary
        case formField(MultipartFieldID)
    }

    let request: RequestNodeID
    let target: Target
    let url: URL
}
