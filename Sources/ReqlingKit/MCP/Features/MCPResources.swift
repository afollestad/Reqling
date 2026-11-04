import Foundation
import MCP

/// Read-only views of projects, requests, and last responses as MCP resources, in the same JSON the matching tools
/// return, for clients that attach resources as context.
@MainActor
final class MCPResources {
    private let context: MCPToolContext

    init(context: MCPToolContext) {
        self.context = context
    }

    nonisolated static let templates = [
        Resource.Template(
            uriTemplate: "reqling://projects/{project}",
            name: "Project",
            description: "A project's environments and folder and request tree, as get_project returns it.",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "reqling://projects/{project}/requests/{request}",
            name: "Request",
            description: "A saved request's spec, as get_request returns it.",
            mimeType: "application/json"
        ),
        Resource.Template(
            uriTemplate: "reqling://projects/{project}/responses/{request}",
            name: "Last response",
            description: "A saved request's latest run, as get_last_response returns it.",
            mimeType: "application/json"
        )
    ]

    /// One resource per open project; requests and responses are reached through the templates.
    func list() -> [Resource] {
        context.library.projects.map { project in
            Resource(
                name: project.name,
                uri: "reqling://projects/\(project.id)",
                description: "The “\(project.name)” project",
                mimeType: "application/json"
            )
        }
    }

    func read(_ uri: String) async throws -> ReadResource.Result {
        let parts = uri.hasPrefix("reqling://projects/") ? uri.dropFirst("reqling://projects/".count).split(separator: "/").map(String.init) : []
        let tool: String
        var arguments: [String: Value] = [:]
        switch parts.count {
        case 1:
            tool = "get_project"
            arguments = ["project": .string(parts[0])]
        case 3 where parts[1] == "requests":
            tool = "get_request"
            arguments = ["project": .string(parts[0]), "request": .string(parts[2])]
        case 3 where parts[1] == "responses":
            tool = "get_last_response"
            arguments = ["project": .string(parts[0]), "request": .string(parts[2])]
        default:
            throw MCPError.invalidParams("Unknown resource \(uri).")
        }
        guard let dispatcher = context.dispatcher else {
            throw MCPError.internalError("The server isn't running.")
        }
        let result = await dispatcher.call(tool, arguments: arguments)
        guard !result.isError else {
            throw MCPError.invalidParams(result.text)
        }
        return ReadResource.Result(contents: [.text(result.text, uri: uri, mimeType: "application/json")])
    }
}
