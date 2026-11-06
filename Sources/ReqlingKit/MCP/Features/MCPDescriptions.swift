import Foundation
import MCP
import ReqlingTemplating

/// How tools describe Reqling's data to agents. Specs, auth, and certificate entries use their on-disk JSON, so what an
/// agent reads is exactly what it can send back to the create and update tools.
@MainActor
enum MCPDescriptions {
    static func project(_ project: LibraryProject, workspace: WorkspaceStateStore) -> [String: Value] {
        var summary: [String: Value] = [
            "id": .string(project.id.description),
            "name": .string(project.name),
            "path": .string(project.url.path),
            "readOnly": .bool(project.isReadOnly)
        ]
        if let document = project.document {
            let active = workspace.activeEnvironment(in: document)
            summary["status"] = "loaded"
            summary["environmentCount"] = .int(document.allEnvironments.count)
            summary["requestCount"] = .int(document.allRequests.count)
            summary["activeEnvironment"] = environmentReference(active)
        } else {
            summary["status"] = "unavailable"
            summary["reason"] = .string(project.unavailableReason ?? "")
        }
        return summary
    }

    static func environmentReference(_ environment: RequestEnvironment) -> Value {
        ["id": .string(environment.id.description), "name": .string(environment.name)]
    }

    static func environment(_ environment: RequestEnvironment, in document: ProjectDocument, active: EnvironmentID) -> [String: Value] {
        [
            "id": .string(environment.id.description),
            "name": .string(environment.name),
            "isGlobal": .bool(environment.id == RequestEnvironment.globalID),
            "isDefault": .bool(document.isDefaultEnvironment(environment.id)),
            "isActive": .bool(environment.id == active),
            "variableCount": .int(environment.variables.count)
        ]
    }

    /// A secret's value is never included; `secret: true` says one is stored.
    static func variable(_ variable: Variable) -> Value {
        var description: [String: Value] = [
            "key": .string(variable.key),
            "enabled": .bool(variable.isEnabled),
            "secret": .bool(variable.isSecret)
        ]
        if !variable.isSecret {
            description["value"] = .string(variable.value)
        }
        return .object(description)
    }

    /// A current value a script set: its value unless it's secret, or `unset: true` for a marker hiding the saved value.
    static func currentValue(_ current: CurrentVariable, key: String) -> Value {
        var description: [String: Value] = ["key": .string(key)]
        switch current {
        case .value(let variable):
            description["secret"] = .bool(variable.isSecret)
            if !variable.isSecret {
                description["value"] = .string(variable.value)
            }
        case .unset:
            description["unset"] = .bool(true)
        }
        return .object(description)
    }

    /// One line per request: enough to pick it, without its whole spec.
    static func requestSummary(_ request: RequestItem, folderPath: [String]) -> Value {
        var summary: [String: Value] = [
            "id": .string(request.id.description),
            "name": .string(request.name),
            "kind": .string(request.kind.name.rawValue),
            "folderPath": .array(folderPath.map(Value.string))
        ]
        switch request.kind {
        case .http(let spec):
            summary["method"] = .string(spec.method.rawValue)
            summary["url"] = .string(spec.displayURL)
        case .grpc(let spec):
            summary["target"] = .string(spec.target)
            summary["rpc"] = .string(spec.methodPath)
        case .webSocket(let spec):
            summary["url"] = .string(spec.displayURL)
        }
        return .object(summary)
    }

    /// The request with its full spec, as stored.
    static func request(_ request: RequestItem, in document: ProjectDocument) throws -> [String: Value] {
        guard case .object(var description) = try MCPJSON.encode(request) else {
            return [:]
        }
        description["scripts"] = MCPScripts.describe(request.scripts)
        description["inheritScripts"] = .bool(request.runsInheritedScripts)
        description["folderPath"] = .array(document.ancestors(of: request.id).map { Value.string($0.name) })
        description["parentFolder"] = document.parentID(of: request.id).map { .string($0.description) } ?? .null
        return description
    }

    /// The folder and request tree, requests summarized.
    static func tree(_ nodes: [RequestNode], path: [String] = []) -> Value {
        .array(nodes.map { node in
            switch node {
            case .request(let request):
                return requestSummary(request, folderPath: path)
            case .folder(let folder):
                var description: [String: Value] = [
                    "id": .string(folder.id.description),
                    "name": .string(folder.name),
                    "kind": "folder",
                    "auth": (try? MCPJSON.encode(folder.auth)) ?? .null,
                    "children": tree(folder.children, path: path + [folder.name])
                ]
                if !folder.scripts.isEmpty {
                    description["scripts"] = MCPScripts.describe(folder.scripts)
                }
                if !folder.runsInheritedScripts {
                    description["inheritScripts"] = false
                }
                return .object(description)
            }
        })
    }
}
