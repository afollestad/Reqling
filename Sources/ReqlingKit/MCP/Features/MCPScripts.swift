import Foundation
import MCP
import ReqlingScriptProtocol

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

    @MainActor static var referenceTool: MCPTool {
        MCPTool(
            "get_script_reference",
            title: "Get script reference",
            description: "The API pre-request and post-response scripts use, as Markdown: `rq`, its types, and which Postman "
                + "`pm` names work. Read it before writing scripts.",
            annotations: .read
        ) { _ in
            .object(["reference": .string(ScriptAPICatalog.reference)])
        }
    }

    /// The problems in the scripts an agent just gave (syntax errors, and names that don't work where they run), so it
    /// can fix them; `nil` when it gave none, or they have none. `protocols` is `nil` for a folder's or the project's
    /// scripts, which run for every protocol.
    static func problems(_ arguments: MCPArguments, in scripts: ScriptSet, protocols: ScriptProtocols?) async -> Value? {
        guard arguments.contains("scripts") else {
            return nil
        }
        let found = await Task.detached { () -> [String: Value] in
            var found: [String: Value] = [:]
            for phase in ScriptPhase.allCases where !scripts[phase].isEmpty {
                let items = problems(in: scripts[phase], context: ScriptAnalysisContext(phase: phase, protocols: protocols))
                if !items.isEmpty {
                    found[phase.rawValue] = .array(items)
                }
            }
            return found
        }.value
        return found.isEmpty ? nil : .object(found)
    }

    private static func problems(in source: String, context: ScriptAnalysisContext) -> [Value] {
        let text = source as NSString
        func line(_ offset: Int) -> Int {
            text.substring(to: min(offset, text.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }
        var items: [Value] = []
        if let error = ScriptSyntaxChecker.shared.error(in: source) {
            items.append(["line": .int(error.line), "severity": "error", "message": .string(error.message)])
        }
        for diagnostic in ScriptAnalyzer(text: source, context: context).diagnostics() {
            items.append(["line": .int(line(diagnostic.range.location)), "severity": "warning", "message": .string(diagnostic.message)])
        }
        return items
    }
}
