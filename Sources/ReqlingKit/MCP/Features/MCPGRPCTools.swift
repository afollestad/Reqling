import Foundation
import MCP

/// Proto definitions, compiling them, browsing a schema, and the protoc Reqling compiles with.
@MainActor
struct MCPGRPCTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [getProtoConfig, updateProtoConfig, compileProtos, listServices, describeMethod, getProtocStatus, installProtoc]
    }

    private var getProtoConfig: MCPTool {
        MCPTool(
            "get_proto_config",
            title: "Get proto definitions",
            description: "A project's proto roots, entry files, and descriptor sets, with the last compile's status.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            return .object(describe(document.grpc, in: project.id))
        }
    }

    private var updateProtoConfig: MCPTool {
        let path: Value = MCPSchema.object([
            "path": MCPSchema.string("Relative to the project folder (shared with everyone who has the project), or absolute."),
            "local": MCPSchema.boolean("Keep an absolute path on this Mac only instead of in the project's files. Needed for "
                + "a path outside the project's folder and repository.")
        ], required: ["path"])
        return MCPTool(
            "update_proto_config",
            title: "Update proto definitions",
            description: "Sets a project's proto roots (folders passed to protoc as import paths), entry files (the .proto files "
                + "to compile, relative to a root; empty compiles every one), and descriptor sets (.protoset/.binpb). Each list "
                + "given replaces the current one; omitted lists stay. Recompiles afterwards.",
            properties: [
                "project": MCPSchema.project,
                "protoRoots": MCPSchema.array(path, "Folders holding .proto files."),
                "protoFiles": MCPSchema.array(["type": "string"], "Entry files, such as acme/v1/users.proto."),
                "descriptorSets": MCPSchema.array(path, "Compiled descriptor set files.")
            ],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            var grpc = document.grpc
            if let roots = try arguments.objects("protoRoots", allowed: ["path", "local"]) {
                grpc.protoRoots = try roots.map { try context.pathReference($0, in: project, existing: document.grpc.protoRoots) }
            }
            if let files = try arguments.stringArray("protoFiles") {
                grpc.protoFiles = files.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            if let sets = try arguments.objects("descriptorSets", allowed: ["path", "local"]) {
                grpc.descriptorSets = try sets.map { try context.pathReference($0, in: project, existing: document.grpc.descriptorSets) }
            }
            let updated = grpc
            try context.mutate(project.id) { $0.grpc = updated }
            return .object(try await compiled(project.id))
        }
    }

    private var compileProtos: MCPTool {
        MCPTool(
            "compile_protos",
            title: "Compile protos",
            description: "Recompiles a project's proto definitions and returns its services, or protoc's errors with file:line.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .edit,
            timeout: .seconds(180)
        ) { arguments in
            let (project, _) = try context.document(try arguments.string("project"))
            context.lifecycle.syncProtoWorkspaces()
            context.protoWorkspaces.workspace(for: project.id)?.recompile()
            return .object(try await compiled(project.id))
        }
    }

    private var listServices: MCPTool {
        MCPTool(
            "grpc_list_services",
            title: "List gRPC services",
            description: "The services and methods a schema defines: a gRPC request's (through its schema source, which may ask "
                + "the server by reflection), or else the project's compiled protos.",
            properties: [
                "project": MCPSchema.project,
                "request": MCPSchema.string("A gRPC request whose schema to read. Omit for the project's protos.")
            ],
            required: ["project"],
            annotations: .networkRead,
            timeout: .seconds(120)
        ) { arguments in
            let registry = try await schema(arguments)
            return .object(["services": .array(registry.services.map { service in
                [
                    "name": .string(service.fullName),
                    "methods": .array(service.methods.map { method in
                        [
                            "name": .string(method.name),
                            "rpc": .string(method.path),
                            "kind": .string(method.kind.rawValue),
                            "input": .string(method.inputType),
                            "output": .string(method.outputType)
                        ]
                    })
                ]
            })])
        }
    }

    private var describeMethod: MCPTool {
        MCPTool(
            "grpc_describe_method",
            title: "Describe gRPC method",
            description: "A method's kind, its input and output messages' fields, and an example input with every field filled.",
            properties: [
                "project": MCPSchema.project,
                "rpc": MCPSchema.string("The method as package.Service/Method."),
                "request": MCPSchema.string("A gRPC request whose schema to read. Omit for the project's protos.")
            ],
            required: ["project", "rpc"],
            annotations: .networkRead,
            timeout: .seconds(120)
        ) { arguments in
            let registry = try await schema(arguments)
            let rpc = try arguments.string("rpc")
            guard let method = registry.method(rpc) else {
                throw MCPToolError("The schema has no method \(rpc); grpc_list_services lists them.")
            }
            let codec = ProtobufJSONCodec(registry: registry)
            return .object([
                "rpc": .string(method.path),
                "kind": .string(method.kind.rawValue),
                "input": .object(["type": .string(method.inputType), "fields": fields(of: method.inputType, codec: codec)]),
                "output": .object(["type": .string(method.outputType), "fields": fields(of: method.outputType, codec: codec)]),
                "exampleInput": .string(codec.example(for: method.inputType))
            ])
        }
    }

    private var getProtocStatus: MCPTool {
        MCPTool(
            "get_protoc_status",
            title: "Get protoc status",
            description: "Which protoc Reqling compiles project protos with, and where it came from, or that none was found.",
            annotations: .read,
            timeout: .seconds(60)
        ) { _ in
            guard let host = context.host else {
                throw MCPToolError("Reqling's window isn't ready yet; try again in a moment.")
            }
            return .object(Self.describe(await host.protocStatus()))
        }
    }

    private var installProtoc: MCPTool {
        MCPTool(
            "install_protoc",
            title: "Install protoc",
            description: "Downloads Reqling's pinned protoc release, checks its SHA-256, and installs it for Reqling alone, as "
                + "Settings ▸ gRPC does. Only needed when get_protoc_status finds none.",
            annotations: .network,
            timeout: .seconds(600)
        ) { _ in
            guard let host = context.host else {
                throw MCPToolError("Reqling's window isn't ready yet; try again in a moment.")
            }
            do {
                return .object(Self.describe(.found(try await host.installProtoc())))
            } catch {
                throw MCPToolError("Installing protoc failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func describe(_ configuration: ProjectGRPCConfiguration, in project: ProjectID) -> [String: Value] {
        var description: [String: Value] = [
            "protoRoots": .array(configuration.protoRoots.map { context.describePath($0, in: project) }),
            "protoFiles": .array(configuration.protoFiles.map(Value.string)),
            "descriptorSets": .array(configuration.descriptorSets.map { context.describePath($0, in: project) })
        ]
        if let workspace = context.protoWorkspaces.workspace(for: project) {
            description["status"] = Self.describe(workspace.status)
            description["warnings"] = .array(workspace.warnings.map { .string($0.description) })
        } else {
            description["status"] = ["state": "empty"]
        }
        return description
    }

    /// The project's workspace after its current compile finishes, with its services.
    private func compiled(_ project: ProjectID) async throws -> [String: Value] {
        context.lifecycle.syncProtoWorkspaces()
        if let workspace = context.protoWorkspaces.workspace(for: project) {
            await workspace.settled()
        }
        let (_, document) = try context.document(project.description)
        var description = describe(document.grpc, in: project)
        if let registry = context.protoWorkspaces.workspace(for: project)?.registry {
            description["services"] = .array(registry.services.map { .string($0.fullName) })
        }
        return description
    }

    private func schema(_ arguments: MCPArguments) async throws -> DescriptorRegistry {
        let (project, document) = try context.document(try arguments.string("project"))
        if let reference = try arguments.optionalString("request") {
            let request = try context.request(reference, in: document)
            context.lifecycle.syncProtoWorkspaces()
            do {
                return try await context.runner.grpcSchema(for: request.id, in: project.id, options: RunOptions(allowUnresolved: true)).registry
            } catch {
                throw MCPToolError(error.message)
            }
        }
        context.lifecycle.syncProtoWorkspaces()
        guard let workspace = context.protoWorkspaces.workspace(for: project.id) else {
            throw MCPToolError("“\(document.name)” has no proto definitions; update_proto_config adds them, or pass a gRPC `request` "
                + "to use its schema source.")
        }
        await workspace.settled()
        guard !workspace.registry.isEmpty else {
            throw MCPToolError("The project's protos haven't compiled: \(MCPJSON.text(Self.describe(workspace.status)))")
        }
        return workspace.registry
    }

    private func fields(of typeName: String, codec: ProtobufJSONCodec) -> Value {
        guard let schema = try? codec.schema(for: DescriptorRegistry.normalized(typeName)) else {
            return []
        }
        return .array(schema.fields.map { field in
            var description: [String: Value] = [
                "name": .string(field.jsonName),
                "type": .string(field.typeName.isEmpty ? "\(field.kind)" : field.typeName)
            ]
            if field.isMap {
                description["map"] = true
            } else if field.isRepeated {
                description["repeated"] = true
            }
            if field.oneofIndex != nil {
                description["oneof"] = true
            }
            return .object(description)
        })
    }

    static func describe(_ status: ProtoWorkspace.Status) -> Value {
        switch status {
        case .empty:
            ["state": "empty"]
        case .compiling:
            ["state": "compiling"]
        case .ready(let serviceCount, let compiledAt):
            ["state": "ready", "serviceCount": .int(serviceCount), "compiledAt": .string(ISO8601DateFormatter().string(from: compiledAt))]
        case .needsProtoc:
            ["state": "needsProtoc", "message": "Compiling the proto roots needs protoc; install_protoc installs one."]
        case .failed(let diagnostics):
            ["state": "failed", "errors": .array(diagnostics.map { .string($0.description) })]
        case .missingPaths(let paths):
            ["state": "missingPaths", "missing": .array(paths.map(Value.string))]
        }
    }

    static func describe(_ status: MCPProtocStatus) -> [String: Value] {
        switch status {
        case .found(let installation):
            [
                "found": true,
                "path": .string(installation.executable.path),
                "version": .string(installation.version),
                "source": .string("\(installation.source)")
            ]
        case .missing:
            ["found": false]
        case .invalidOverride(let path):
            ["found": false, "invalidOverride": .string(path), "message": "The protoc path set in Settings isn't a working protoc."]
        }
    }
}
