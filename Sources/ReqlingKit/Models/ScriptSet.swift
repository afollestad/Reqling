import ReqlingScriptProtocol

extension ScriptPhase {
    /// What follows the owner's file name in the phase's file: `list-users.pre.js`, `_folder.post.js`.
    var fileSuffix: String {
        switch self {
        case .preRequest: "pre"
        case .postResponse: "post"
        }
    }
}

/// A request's, folder's, or project's scripts, as typed. Each lives in its own `.js` file beside the owner's JSON
/// (`ProjectLayout.scriptPath`), so it diffs and edits as code; an empty script has no file.
public struct ScriptSet: Hashable, Sendable {
    public var preRequest: String
    public var postResponse: String

    public init(preRequest: String = "", postResponse: String = "") {
        self.preRequest = preRequest
        self.postResponse = postResponse
    }

    public subscript(phase: ScriptPhase) -> String {
        get {
            switch phase {
            case .preRequest: preRequest
            case .postResponse: postResponse
            }
        }
        set {
            switch phase {
            case .preRequest: preRequest = newValue
            case .postResponse: postResponse = newValue
            }
        }
    }

    public var isEmpty: Bool {
        preRequest.isEmpty && postResponse.isEmpty
    }
}
