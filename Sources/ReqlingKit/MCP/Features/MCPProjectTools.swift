import Foundation
import MCP

/// Projects: listing, reading, creating, renaming, and removing them from Reqling or deleting them to the Trash.
@MainActor
struct MCPProjectTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [listProjects, getProject, createProject, updateProject, deleteProject, addProjectFolder, removeProject]
    }

    private var listProjects: MCPTool {
        MCPTool(
            "list_projects",
            title: "List projects",
            description: "Every project open in Reqling, with its ID, folder, active environment, and counts.",
            annotations: .read
        ) { _ in
            .object(["projects": .array(context.library.projects.map { .object(MCPDescriptions.project($0, workspace: context.workspace)) })])
        }
    }

    private var getProject: MCPTool {
        MCPTool(
            "get_project",
            title: "Get project",
            description: "A project's details: its auth, environments, and the full folder and request tree with IDs.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let active = context.workspace.activeEnvironment(in: document).id
            var description = MCPDescriptions.project(project, workspace: context.workspace)
            description["auth"] = try MCPJSON.encode(document.auth)
            description["scripts"] = MCPScripts.describe(document.scripts)
            description["environments"] = .array(document.allEnvironments.map {
                .object(MCPDescriptions.environment($0, in: document, active: active))
            })
            description["items"] = MCPDescriptions.tree(document.items)
            return .object(description)
        }
    }

    private var createProject: MCPTool {
        MCPTool(
            "create_project",
            title: "Create project",
            description: "Creates a project folder with its Default environment and opens it in Reqling.",
            properties: [
                "name": MCPSchema.string("The project's name, which also names its folder."),
                "location": MCPSchema.string("An absolute directory to create the project folder in, such as an API's repository. "
                    + "Omit for Reqling's own projects folder.")
            ],
            required: ["name"],
            annotations: .create
        ) { arguments in
            let name = try arguments.string("name")
            let location = try arguments.optionalString("location").map { try Self.absoluteURL($0, field: "location") }
            let id = try context.lifecycle.createProject(named: name, in: location)
            guard let project = context.library.project(id) else {
                throw MCPToolError("The project was created but didn't open.")
            }
            return .object(["project": .object(MCPDescriptions.project(project, workspace: context.workspace))])
        }
    }

    private var updateProject: MCPTool {
        MCPTool(
            "update_project",
            title: "Update project",
            description: "Renames a project, or sets the auth its requests inherit or the scripts every request runs. Omitted fields "
                + "keep their value.",
            properties: [
                "project": MCPSchema.project,
                "name": MCPSchema.string("A new name. The project folder keeps its name."),
                "auth": MCPSchema.openObject("Auth for requests that inherit it, as get_project returns it: "
                    + #"{"type": "none"}, {"type": "bearer", "token": "{{token}}"}, "#
                    + #"{"type": "basic", "username": "…", "password": "…"}, or "#
                    + #"{"type": "apiKey", "name": "X-API-Key", "value": "…", "location": "header" | "query"}."#),
                "scripts": MCPScripts.schema
            ],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let (project, current) = try context.document(try arguments.string("project"))
            let name = try arguments.optionalString("name")
            let auth = try arguments.optionalObject("auth").map { try MCPJSON.decode(HTTPAuth.self, from: .object($0), path: "auth") }
            var scripts = current.scripts
            try MCPScripts.apply(arguments, to: &scripts)
            try context.mutate(project.id) { document in
                document.scripts = scripts
                if let name {
                    document.name = name
                }
                if let auth {
                    document.auth = auth == .inherit ? .none : auth
                }
            }
            var result: [String: Value] = [
                "project": .object(MCPDescriptions.project(try context.project(project.id.description), workspace: context.workspace))
            ]
            result["scriptProblems"] = await MCPScripts.problems(arguments, in: scripts, protocols: nil)
            return .object(result)
        }
    }

    private var deleteProject: MCPTool {
        MCPTool(
            "delete_project",
            title: "Delete project",
            description: "Moves the project's folder to the Trash, removes it from Reqling, and deletes its secrets; one that "
                + "syncs with iCloud goes to the Trash on every Mac. To close a project but keep it, use remove_project.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            do {
                try context.lifecycle.deleteProject(project.id)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            return .object(["deleted": .string(project.id.description), "trashed": .string(project.url.path)])
        }
    }

    private var addProjectFolder: MCPTool {
        MCPTool(
            "add_project_folder",
            title: "Open project folder",
            description: "Opens an existing project folder (one holding a project.json), such as one checked into a repository.",
            properties: ["path": MCPSchema.string("The project folder's absolute path.")],
            required: ["path"],
            annotations: .create
        ) { arguments in
            let url = try Self.absoluteURL(try arguments.string("path"), field: "path")
            let id: ProjectID
            do {
                id = try context.lifecycle.addProjectFolder(url)
            } catch {
                throw MCPToolError(error.localizedDescription)
            }
            return .object(["project": .object(MCPDescriptions.project(try context.project(id.description), workspace: context.workspace))])
        }
    }

    private var removeProject: MCPTool {
        MCPTool(
            "remove_project",
            title: "Remove project from Reqling",
            description: "Closes a project in Reqling without touching its folder or secrets, or other Macs that sync it; "
                + "add_project_folder opens it again.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            context.lifecycle.removeProject(project.id)
            return .object(["removed": .string(project.id.description), "path": .string(project.url.path)])
        }
    }

    /// Relative paths would resolve against Reqling's own working directory, which means nothing to the agent.
    static func absoluteURL(_ path: String, field: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw MCPToolError("`\(field)` must be an absolute path.")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
