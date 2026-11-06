import Foundation
import MCP

/// A saved request's past runs on this Mac: listing them, reading one in full, and clearing them. Runs come from
/// Reqling's window and from agents alike; the history is this Mac's alone, never in the project.
@MainActor
struct MCPHistoryTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [listRuns, getRun, clearHistory]
    }

    private var listRuns: MCPTool {
        MCPTool(
            "list_runs",
            title: "List runs",
            description: "A saved request's past runs on this Mac, newest first: when each started, its environment, outcome, "
                + "status, time, and size. get_run returns one in full.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.request,
                "limit": MCPSchema.integer("The most runs to list, newest first; 20 when omitted.", minimum: 1, maximum: 500)
            ],
            required: ["project", "request"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            let limit = try arguments.optionalInteger("limit", in: 1...500) ?? 20
            let runs = context.runner.history.runs(for: request.id, in: project.id)
            return .object(["runs": .array(runs.prefix(limit).map(Self.describe)), "total": .int(runs.count)])
        }
    }

    private var getRun: MCPTool {
        MCPTool(
            "get_run",
            title: "Get run",
            description: "One past run of a saved request, as execute_request returns it, plus `spec`: the template it sent, in "
                + "get_request's form.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.request,
                "run": MCPSchema.string("The run's ID, from list_runs.")
            ],
            required: ["project", "request", "run"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            let reference = try arguments.string("run")
            guard let run = RunID(string: reference) else {
                throw MCPToolError("`run` must be a run's ID from list_runs.")
            }
            // Taken before the read, as `get_last_response` does.
            let mask = context.runner.maskingSecrets(in: project.id)
            guard let exchange = await context.runner.history.exchange(run, for: request.id, in: project.id) else {
                throw MCPToolError("“\(request.name)” has no run \(reference) on this Mac.")
            }
            var description = MCPExecutionTools.describe(exchange, mask: mask)
            description["run"] = .string(run.description)
            if let spec = exchange.spec {
                description["spec"] = try MCPJSON.encode(spec)
            }
            return .object(description)
        }
    }

    private var clearHistory: MCPTool {
        MCPTool(
            "clear_history",
            title: "Clear run history",
            description: "Deletes a saved request's past runs on this Mac, or every request's in the project when `request` is "
                + "omitted. Unlike deleting items, this can't be undone.",
            properties: ["project": MCPSchema.project, "request": MCPSchema.request],
            required: ["project"],
            annotations: .destroy
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            guard let reference = try arguments.optionalString("request") else {
                context.runner.clearHistory(in: project.id)
                return .object(["cleared": .string(project.id.description)])
            }
            let request = try context.request(reference, in: document)
            context.runner.clearHistory(for: request.id, in: project.id)
            return .object(["cleared": .string(request.id.description)])
        }
    }

    private static func describe(_ run: RunSummary) -> Value {
        var description: [String: Value] = [
            "run": .string(run.id.description),
            "startedAt": .string(ISO8601DateFormatter().string(from: run.startedAt)),
            "environment": run.environmentName.map(Value.string) ?? .null,
            "outcome": .string(run.outcomeKind.rawValue)
        ]
        switch run.status {
        case .http(let code):
            description["status"] = .int(code)
        case .grpc(_, let name):
            description["status"] = name.map(Value.string) ?? .null
        case .webSocket(.refused(let code)):
            description["status"] = .int(code)
        case .webSocket(.closed(let code)):
            description["closeCode"] = .int(code ?? 1005)
        case .webSocket(.unclosed):
            description["closeCode"] = .int(1006)
        case .failure(let kind):
            description["failure"] = .string(kind.rawValue)
        }
        if let duration = run.duration {
            description["durationMs"] = .int(Int((duration * 1_000).rounded()))
        }
        if let bytes = run.responseByteCount {
            description["byteCount"] = .int(bytes)
        }
        return .object(description)
    }
}
