import Foundation
import MCP

/// What the request and folder tools share: moving and deleting tree items, the spec schemas, and applying an agent's
/// spec or patch.
extension MCPRequestTools {
    /// A kind of tree item a tool acts on: what to call it, the argument naming it, and how to find it.
    struct TreeTarget {
        let noun: String
        let argument: String
        let schema: Value
        let resolve: @MainActor (String, ProjectDocument) throws -> RequestNodeID
    }

    func move(_ name: String, title: String, target: TreeTarget) -> MCPTool {
        let argument = target.argument
        return MCPTool(
            name,
            title: title,
            description: "Moves a \(target.noun) into another folder, out to the top level, or into another project, or "
                + "reorders it. Its file moves with it.",
            properties: [
                "project": MCPSchema.project,
                argument: target.schema,
                "destinationProject": MCPSchema.string("The project to move into, by ID or unique name. Omit to stay in this one."),
                "destinationFolder": MCPSchema.string("The folder to move into, by ID, in the destination project. Omit for its top level."),
                "index": MCPSchema.integer("Position in the destination, from 0, counted without the moved item. Omit to append.", minimum: 0)
            ],
            required: ["project", argument],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let id = try target.resolve(try arguments.string(argument), document)
            let destination = try arguments.optionalString("destinationProject").map { try context.document($0) }
                ?? (project: project, document: document)
            let parent = try arguments.optionalString("destinationFolder").map { try context.folder($0, in: destination.document).id }
            let index = try arguments.optionalInteger("index", in: 0...Int.max)
            let move: ProjectNodeMove = try context.describingErrors {
                do {
                    return try context.lifecycle.moveNode(id, from: project.id, to: destination.project.id, into: parent, at: index)
                } catch ProjectMoveError.leftInSource(let error) {
                    throw MCPToolError("It was added to “\(destination.project.name)” but couldn't leave “\(project.name)”, so "
                        + "it is in both: \(error.localizedDescription)")
                }
            }
            let moved = try context.document(destination.project.id.description).document
            var result: [String: Value] = [
                "moved": .string(move.nodeID.description),
                "project": .string(destination.project.id.description),
                "folderPath": .array(moved.ancestors(of: move.nodeID).map { Value.string($0.name) })
            ]
            if !move.localizedPaths.isEmpty {
                result["warnings"] = .array(move.localizedPaths.map { path in
                    .string("\(path) is outside “\(destination.project.name)”'s folder and repository, so it is now a "
                        + "this-Mac-only path.")
                })
            }
            return .object(result)
        }
    }

    func delete(_ name: String, title: String, target: TreeTarget) -> MCPTool {
        let argument = target.argument
        return MCPTool(
            name,
            title: title,
            description: "Moves a \(target.noun) to the Trash, where Finder's Put Back restores it.",
            properties: ["project": MCPSchema.project, argument: target.schema],
            required: ["project", argument],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let id = try target.resolve(try arguments.string(argument), document)
            try context.describingErrors { try context.lifecycle.deleteNode(id, in: project.id) }
            return .object(["deleted": .string(id.description)])
        }
    }

    static let httpSpecSchema = MCPSchema.openObject(
        "An HTTP spec: method, url (any query string moves into queryParameters), queryParameters and headers "
            + #"([{"key", "value", "enabled"}]), body ({"mode": "none" | "raw" | "form-data" | "x-www-form-urlencoded" | "#
            + #""binary" | "graphql", "raw": {"text", "contentType"}, "x-www-form-urlencoded": [{"key", "value"}], "graphql": "#
            + #"{"query", "variables"}}), auth (as update_project describes, or {"type": "inherit"}), and options "#
            + #"({"timeoutSeconds", "followRedirects", "verifyTLS"}). Values may contain {{variables}}."#
    )

    static let grpcSpecSchema = MCPSchema.openObject(
        #"A gRPC spec: target ("host:port" or "unix:/path"), security ("plaintext" | "tls"), service, method, metadata "#
            + #"([{"key", "value", "enabled"}]), messages (proto3 JSON strings, in order), schema ({"type": "automatic" | "#
            + #""projectProtos" | "reflection"} or {"type": "descriptorSet", "file": {"relative": "path"}}), auth, deadlineSeconds."#
    )

    static let folderAuthSchema = MCPSchema.openObject(
        #"Auth for the folder's requests that inherit it: {"type": "inherit"} (the default: from the parent or project), "#
            + #"{"type": "none"}, or the bearer, basic, and apiKey forms update_project describes."#
    )

    /// The spec `http` or `grpc` names, normalized as any outside spec must be.
    static func kind(from arguments: MCPArguments) throws -> RequestKind {
        let http = try arguments.optionalObject("http")
        let grpc = try arguments.optionalObject("grpc")
        switch (http, grpc) {
        case (.some, .some):
            throw MCPToolError("Pass `http` or `grpc`, not both.")
        case (let http?, nil):
            return .http(try MCPJSON.decode(HTTPRequestSpec.self, from: .object(http), path: "http").normalized())
        case (nil, let grpc?):
            return .grpc(try MCPJSON.decode(GRPCRequestSpec.self, from: .object(grpc), path: "grpc"))
        case (nil, nil):
            return .http(HTTPRequestSpec())
        }
    }

    /// `kind`'s spec with an RFC 7396 merge patch applied to its JSON.
    static func patched(_ kind: RequestKind, with patch: Value) throws -> RequestKind {
        switch kind {
        case .http(let spec):
            let merged = mergePatch(try MCPJSON.encode(spec), patch)
            return .http(try MCPJSON.decode(HTTPRequestSpec.self, from: merged, path: "spec").normalized())
        case .grpc(let spec):
            let merged = mergePatch(try MCPJSON.encode(spec), patch)
            return .grpc(try MCPJSON.decode(GRPCRequestSpec.self, from: merged, path: "spec"))
        }
    }

    /// RFC 7396, except that a list of rows merges by `id`: a row naming an existing one merges into it and keeps its
    /// identity, so the editor's row-by-row merge still tells the agent's edit from the user's; a row without one gets a
    /// fresh ID, since one derived from its position could match an unrelated row from another update.
    static func mergePatch(_ target: Value, _ patch: Value) -> Value {
        switch patch {
        case .object(let changes):
            var result = target.objectValue ?? [:]
            for (key, change) in changes {
                if change == .null {
                    result.removeValue(forKey: key)
                } else {
                    result[key] = mergePatch(result[key] ?? .null, change)
                }
            }
            return .object(result)
        case .array(let items):
            var existing: [String: Value] = [:]
            for row in target.arrayValue ?? [] {
                if let id = row.objectValue?["id"]?.stringValue {
                    existing[id.lowercased()] = row
                }
            }
            return .array(items.map { item in
                guard case .object(var row) = item else {
                    return item
                }
                if let id = row["id"]?.stringValue, let current = existing[id.lowercased()] {
                    return mergePatch(current, item)
                }
                if row["id"] == nil {
                    row["id"] = .string(UUID().uuidString.lowercased())
                }
                return .object(row)
            })
        default:
            return patch
        }
    }

    static func defaultName(for spec: HTTPRequestSpec) -> String {
        let path = URLComponents(string: spec.url)?.path ?? ""
        return path.isEmpty || path == "/" ? spec.method.rawValue : "\(spec.method.rawValue) \(path)"
    }
}

extension MCPRequestTools {
    var requestTarget: TreeTarget {
        TreeTarget(noun: "request", argument: "request", schema: MCPSchema.request) { [context] reference, document in
            try context.request(reference, in: document).id
        }
    }

    func folderTarget(noun: String) -> TreeTarget {
        TreeTarget(noun: noun, argument: "folder", schema: MCPSchema.string("The folder's ID.")) { [context] reference, document in
            try context.folder(reference, in: document).id
        }
    }
}
