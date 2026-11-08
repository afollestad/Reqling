import Foundation
import MCP
import ReqlingScriptProtocol

/// A request's, folder's, or project's scripts in tool arguments and results. Scripts live in `.js` files beside their
/// owner's JSON rather than in it, so they travel as this explicit object instead of inside the on-disk JSON the other
/// fields use.
enum MCPScripts {
    /// Keyed by each phase's raw value.
    static let schema = MCPSchema.object(
        Dictionary(uniqueKeysWithValues: ScriptPhase.allCases.map { ($0.rawValue, MCPSchema.string(summary(of: $0))) }),
        description: "Its scripts; a field left out keeps its script."
    )

    static let inheritSchema = MCPSchema.boolean(
        "Whether enclosing folders' and the project's scripts run around this one's. Defaults to true."
    )

    static func describe(_ scripts: ScriptSet) -> Value {
        .object(Dictionary(uniqueKeysWithValues: ScriptPhase.allCases.map { ($0.rawValue, Value.string(scripts[$0])) }))
    }

    /// Applies the `scripts` argument, if any, keeping each script it leaves out.
    static func apply(_ arguments: MCPArguments, to scripts: inout ScriptSet) throws {
        guard let given = try arguments.nested("scripts", allowed: Set(ScriptPhase.allCases.map(\.rawValue))) else {
            return
        }
        for phase in ScriptPhase.allCases {
            scripts[phase] = try given.optionalRawString(phase.rawValue) ?? scripts[phase]
        }
    }

    private static func summary(of phase: ScriptPhase) -> String {
        switch phase {
        case .preRequest:
            "JavaScript run before the request is resolved and sent. \"\" removes it."
        case .stream:
            "JavaScript run when an event stream, WebSocket, or gRPC call opens; its rq.onEvent and rq.onMessage handlers run "
                + "on each event or message received. \"\" removes it."
        case .postResponse:
            "JavaScript run after the response arrives or the stream, call, or connection ends. \"\" removes it."
        }
    }

    @MainActor static var referenceTool: MCPTool {
        MCPTool(
            "get_script_reference",
            title: "Get script reference",
            description: "The API pre-request, stream, and post-response scripts use, as Markdown: `rq`, its types, and which "
                + "Postman `pm` names work. Read it before writing scripts.",
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
        ScriptProblem.find(in: source, context: context).map { problem in
            ["line": .int(problem.line), "severity": problem.severity == .error ? "error" : "warning", "message": .string(problem.message)]
        }
    }
}
