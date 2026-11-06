/// Whether a project's scripts may run on this Mac. Kept per Mac in `ProjectWorkspaceState`, never in the project, so
/// cloning a repository never brings its trust along: a script can read every variable in scope, secrets and Global's
/// included, and add them to the project's own requests.
public enum ScriptTrust: String, Hashable, Sendable, Codable {
    /// Not yet asked. Projects created in Reqling, or by an agent through MCP, start trusted instead.
    case unknown
    case trusted
    /// Its requests run without scripts.
    case declined
}

/// Asks the person at the Mac whether a project's scripts may run; the app's alert. Only runs the person started may
/// ask (`RunOptions.mayPromptForTrust`), never an agent's or a background schema fetch.
@MainActor
public protocol ScriptTrustDeciding: AnyObject {
    /// `true` to trust, `false` to decline, or `nil` when the question was dismissed unanswered, which runs without
    /// scripts this time and asks again next time. `files` lists the scripts that would run.
    func decideScriptTrust(projectName: String, files: [String]) async -> Bool?
}
