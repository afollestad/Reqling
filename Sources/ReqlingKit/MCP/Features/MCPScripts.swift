import MCP

/// A request's, folder's, or project's scripts in tool arguments and results. Scripts live in `.js` files beside their
/// owner's JSON rather than in it, so they travel as this explicit object instead of inside the on-disk JSON the other
/// fields use.
enum MCPScripts {
    static let schema = MCPSchema.object([
        "preRequest": MCPSchema.string("JavaScript run before the request is resolved and sent. \"\" removes it."),
        "postResponse": MCPSchema.string("JavaScript run after the response arrives or the stream, call, or connection ends. \"\" removes it.")
    ], description: "Its scripts; a field left out keeps its script.")

    static let inheritSchema = MCPSchema.boolean(
        "Whether enclosing folders' and the project's scripts run around this one's. Defaults to true."
    )

    static func describe(_ scripts: ScriptSet) -> Value {
        ["preRequest": .string(scripts.preRequest), "postResponse": .string(scripts.postResponse)]
    }

    /// Applies the `scripts` argument, if any, keeping each script it leaves out.
    static func apply(_ arguments: MCPArguments, to scripts: inout ScriptSet) throws {
        guard let given = try arguments.nested("scripts", allowed: ["preRequest", "postResponse"]) else {
            return
        }
        scripts.preRequest = try given.optionalRawString("preRequest") ?? scripts.preRequest
        scripts.postResponse = try given.optionalRawString("postResponse") ?? scripts.postResponse
    }
}
