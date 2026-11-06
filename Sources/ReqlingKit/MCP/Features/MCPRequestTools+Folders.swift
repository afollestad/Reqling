import MCP

/// Folders: grouping requests, and the auth their requests inherit.
extension MCPRequestTools {
    var createFolder: MCPTool {
        MCPTool(
            "create_folder",
            title: "Create folder",
            description: "Adds a folder to group requests, optionally with auth its requests inherit.",
            properties: [
                "project": MCPSchema.project,
                "name": MCPSchema.string("The folder's name."),
                "folder": MCPSchema.string("The parent folder's ID. Omit for the project's top level."),
                "index": MCPSchema.index,
                "auth": Self.folderAuthSchema,
                "scripts": MCPScripts.schema,
                "inheritScripts": MCPScripts.inheritSchema
            ],
            required: ["project", "name"],
            annotations: .create
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let auth = try arguments.optionalObject("auth").map { try MCPJSON.decode(HTTPAuth.self, from: .object($0), path: "auth") }
            var folder = RequestFolder(name: try arguments.string("name"), auth: auth ?? .inherit)
            try MCPScripts.apply(arguments, to: &folder.scripts)
            folder.runsInheritedScripts = try arguments.bool("inheritScripts", default: true)
            let parent = try arguments.optionalString("folder").map { try context.folder($0, in: document).id }
            let index = try arguments.optionalInteger("index", in: 0...Int.max)
            try context.mutate(project.id) { try $0.insert(.folder(folder), into: parent, at: index) }
            var result: [String: Value] = ["folder": ["id": .string(folder.id.description), "name": .string(folder.name)]]
            result["scriptProblems"] = await MCPScripts.problems(arguments, in: folder.scripts, protocols: nil)
            return .object(result)
        }
    }

    var updateFolder: MCPTool {
        MCPTool(
            "update_folder",
            title: "Update folder",
            description: "Renames a folder, or sets the auth its requests inherit or the scripts they run. Omitted fields keep their value.",
            properties: [
                "project": MCPSchema.project,
                "folder": MCPSchema.string("The folder's ID."),
                "name": MCPSchema.string("A new name."),
                "auth": Self.folderAuthSchema,
                "scripts": MCPScripts.schema,
                "inheritScripts": MCPScripts.inheritSchema
            ],
            required: ["project", "folder"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let folder = try context.folder(try arguments.string("folder"), in: document)
            let name = try arguments.optionalString("name")
            let auth = try arguments.optionalObject("auth").map { try MCPJSON.decode(HTTPAuth.self, from: .object($0), path: "auth") }
            var scripts = folder.scripts
            try MCPScripts.apply(arguments, to: &scripts)
            let inherits = try arguments.optionalBool("inheritScripts") ?? folder.runsInheritedScripts
            try context.mutate(project.id) { document in
                try document.updateFolder(folder.id) { folder in
                    folder.name = name ?? folder.name
                    folder.auth = auth ?? folder.auth
                    folder.scripts = scripts
                    folder.runsInheritedScripts = inherits
                }
            }
            var result: [String: Value] = ["folder": ["id": .string(folder.id.description), "name": .string(name ?? folder.name)]]
            result["scriptProblems"] = await MCPScripts.problems(arguments, in: scripts, protocols: nil)
            return .object(result)
        }
    }

    var moveFolder: MCPTool {
        move("move_folder", title: "Move folder", target: folderTarget(noun: "folder"))
    }

    var deleteFolder: MCPTool {
        delete("delete_folder", title: "Delete folder", target: folderTarget(noun: "folder, with everything inside it,"))
    }
}
