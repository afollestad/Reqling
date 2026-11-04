import Foundation
import MCP

/// Request templates and the folders holding them. Specs are the JSON `get_request` returns, which is the request file's
/// own format; fields left out take their defaults.
@MainActor
struct MCPRequestTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [
            listRequests, getRequest, createRequest, updateRequest, duplicateRequest, moveRequest, deleteRequest,
            createFolder, updateFolder, moveFolder, deleteFolder, importCurl, exportCurl
        ]
    }

    // MARK: - Reading

    private var listRequests: MCPTool {
        MCPTool(
            "list_requests",
            title: "List requests",
            description: "Saved requests with their IDs, kinds, methods or RPCs, URLs or targets, and folders. Every project "
                + "unless one is named.",
            properties: [
                "project": MCPSchema.project,
                "folder": MCPSchema.string("Only requests inside this folder (by ID)."),
                "recursive": MCPSchema.boolean("With a folder, include its subfolders' requests. Defaults to true."),
                "kind": MCPSchema.enumeration(["http", "grpc"], "Only this protocol."),
                "query": MCPSchema.string("Words that must all match a request's name, method, URL, or RPC, ignoring case.")
            ],
            annotations: .read
        ) { arguments in
            let projects = try arguments.optionalString("project").map { [try context.document($0)] }
                ?? context.library.projects.compactMap { project in project.document.map { (project, $0) } }
            let kind = try arguments.optionalString("kind").map { name in
                guard let kind = RequestKind.Name(rawValue: name) else {
                    throw MCPToolError("`kind` must be http or grpc.")
                }
                return kind
            }
            let folder = try arguments.optionalString("folder")
            let recursive = try arguments.bool("recursive", default: true)
            let query = try arguments.optionalString("query") ?? ""
            var results: [Value] = []
            for (project, document) in projects {
                var scope = document
                if let folder {
                    scope.items = try context.folder(folder, in: document).children.filter { recursive || !$0.isFolder }
                }
                scope.items = scope.filtered(matching: query, filter: RequestFilter(protocols: kind.map { [$0] } ?? [])) ?? []
                for (request, _) in scope.allRequests {
                    guard case .object(var summary) = MCPDescriptions.requestSummary(
                        request,
                        folderPath: document.ancestors(of: request.id).map(\.name)
                    ) else {
                        continue
                    }
                    summary["project"] = .string(project.id.description)
                    results.append(.object(summary))
                }
            }
            return .object(["requests": .array(results)])
        }
    }

    private var getRequest: MCPTool {
        MCPTool(
            "get_request",
            title: "Get request",
            description: "A saved request's whole spec, `{{variables}}` unresolved, in the JSON create_request and update_request take.",
            properties: ["project": MCPSchema.project, "request": MCPSchema.request],
            required: ["project", "request"],
            annotations: .read
        ) { arguments in
            let (_, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            return .object(["request": .object(try MCPDescriptions.request(request, in: document))])
        }
    }

    // MARK: - Requests

    private var createRequest: MCPTool {
        MCPTool(
            "create_request",
            title: "Create request",
            description: "Saves a new request template. Pass `http` or `grpc` with its spec (fields left out take their defaults; "
                + "call get_request on an existing request to see the shape), or neither for an empty HTTP GET.",
            properties: [
                "project": MCPSchema.project,
                "name": MCPSchema.string("The request's name in the sidebar."),
                "http": Self.httpSpecSchema,
                "grpc": Self.grpcSpecSchema,
                "folder": MCPSchema.folder,
                "index": MCPSchema.index
            ],
            required: ["project", "name"],
            annotations: .create
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let kind = try Self.kind(from: arguments)
            let request = RequestItem(name: try arguments.string("name"), kind: kind)
            let parent = try arguments.optionalString("folder").map { try context.folder($0, in: document).id }
            let index = try arguments.optionalInteger("index", in: 0...Int.max)
            try context.mutate(project.id) { try $0.insert(.request(request), into: parent, at: index) }
            return .object(["request": .object(try MCPDescriptions.request(request, in: try context.document(project.id.description).document))])
        }
    }

    private var updateRequest: MCPTool {
        MCPTool(
            "update_request",
            title: "Update request",
            description: "Changes a saved request. `spec` is a JSON merge patch on the spec get_request returns: objects merge, "
                + "`null` resets a field to its default, and a list given replaces the list. In row lists (headers, query "
                + "parameters, form fields, metadata) a row with an existing `id` keeps it and merges the fields given, so "
                + #"{"id": "…", "value": "new"} changes one value; a row without `id` is new; a row left out is removed. "#
                + "Its protocol can't change.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.request,
                "name": MCPSchema.string("A new name."),
                "spec": MCPSchema.openObject(#"The fields to change, such as {"method": "POST", "body": {"raw": {"text": "{}"}}}."#)
            ],
            required: ["project", "request"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let original = try context.request(try arguments.string("request"), in: document)
            var updated = original
            if let name = try arguments.optionalString("name") {
                updated.name = name
            }
            if let patch = try arguments.optionalObject("spec") {
                updated.kind = try Self.patched(original.kind, with: .object(patch))
            }
            let result = updated
            try context.mutate(project.id) { try $0.updateRequest(original.id) { $0 = result } }
            return .object(["request": .object(try MCPDescriptions.request(result, in: try context.document(project.id.description).document))])
        }
    }

    private var duplicateRequest: MCPTool {
        MCPTool(
            "duplicate_request",
            title: "Duplicate request",
            description: "Copies a saved request, placing the copy right after it.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.request,
                "name": MCPSchema.string("The copy's name. Defaults to the original's with “Copy” after it.")
            ],
            required: ["project", "request"],
            annotations: .create
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let original = try context.request(try arguments.string("request"), in: document)
            let copy = RequestNode.request(original).copy(named: try arguments.optionalString("name") ?? "\(original.name) Copy")
            let parent = document.parentID(of: original.id)
            let index = (document.children(of: parent) ?? []).firstIndex { $0.id == original.id }.map { $0 + 1 }
            try context.mutate(project.id) { try $0.insert(copy, into: parent, at: index) }
            guard case .request(let request) = copy else {
                throw MCPToolError("The copy isn't a request.")
            }
            return .object(["request": .object(try MCPDescriptions.request(request, in: try context.document(project.id.description).document))])
        }
    }

    private var moveRequest: MCPTool {
        move("move_request", title: "Move request", target: requestTarget)
    }

    private var deleteRequest: MCPTool {
        delete("delete_request", title: "Delete request", target: requestTarget)
    }

    // MARK: - cURL

    private var importCurl: MCPTool {
        MCPTool(
            "import_curl",
            title: "Import cURL command",
            description: "Saves a new HTTP request from a cURL command, as browsers' Copy as cURL writes them. Returns any flags it "
                + "couldn't carry over.",
            properties: [
                "project": MCPSchema.project,
                "command": MCPSchema.string("The command, starting with `curl`."),
                "name": MCPSchema.string("The request's name. Defaults to its method and path."),
                "folder": MCPSchema.folder,
                "index": MCPSchema.index
            ],
            required: ["project", "command"],
            annotations: .create
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let imported: CurlImport
            do {
                imported = try CurlCodec.importCommand(try arguments.string("command"))
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            let spec = imported.spec.normalized()
            let name = try arguments.optionalString("name") ?? Self.defaultName(for: spec)
            let request = RequestItem(name: name, kind: .http(spec))
            let parent = try arguments.optionalString("folder").map { try context.folder($0, in: document).id }
            let index = try arguments.optionalInteger("index", in: 0...Int.max)
            try context.mutate(project.id) { try $0.insert(.request(request), into: parent, at: index) }
            return .object([
                "request": .object(try MCPDescriptions.request(request, in: try context.document(project.id.description).document)),
                "warnings": .array(imported.warnings.map(Value.string))
            ])
        }
    }

    private var exportCurl: MCPTool {
        MCPTool(
            "export_curl",
            title: "Export as cURL",
            description: "A saved HTTP request as a cURL command, resolved against an environment, with secret values masked.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.request,
                "environment": MCPSchema.runEnvironment,
                "variables": MCPSchema.stringMap("One-off values that beat every environment's, by key.")
            ],
            required: ["project", "request"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            var options = RunOptions(variableOverrides: try arguments.stringMap("variables") ?? [:], allowUnresolved: true)
            options.environmentID = try arguments.optionalString("environment").map { try context.environment($0, in: document).id }
            do {
                let prepared = try context.runner.prepare(request.id, in: project.id, options: options)
                return .object([
                    "command": .string(CurlCodec.export(prepared, masked: true)),
                    "unresolvedVariables": .array(prepared.unresolvedVariables.map(Value.string))
                ])
            } catch let failure as RunFailure {
                throw MCPToolError(failure.message)
            }
        }
    }
}
