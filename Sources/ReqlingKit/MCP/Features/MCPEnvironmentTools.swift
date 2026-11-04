import Foundation
import MCP

/// Environments and their `{{variables}}`. Variable tools default to the Default environment, whose values every
/// other environment inherits and overrides by key. Secret values go to the Keychain and are never returned.
@MainActor
struct MCPEnvironmentTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [
            listEnvironments, createEnvironment, updateEnvironment, deleteEnvironment, setActiveEnvironment,
            listVariables, createVariables, updateVariables, deleteVariables
        ]
    }

    // MARK: - Environments

    private var listEnvironments: MCPTool {
        MCPTool(
            "list_environments",
            title: "List environments",
            description: "A project's environments, Default first, and which one is active in the window.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .read
        ) { arguments in
            let (_, document) = try context.document(try arguments.string("project"))
            let active = context.workspace.activeEnvironment(in: document).id
            return .object(["environments": .array(document.allEnvironments.map {
                .object(MCPDescriptions.environment($0, in: document, active: active))
            })])
        }
    }

    private var createEnvironment: MCPTool {
        MCPTool(
            "create_environment",
            title: "Create environment",
            description: "Adds an environment, such as Staging, optionally with variables that override Default's by key.",
            properties: [
                "project": MCPSchema.project,
                "name": MCPSchema.string("A name no other environment in the project has."),
                "variables": Self.newVariablesSchema
            ],
            required: ["project", "name"],
            annotations: .create
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let name = try arguments.string("name")
            try Self.requireUniqueName(name, in: document)
            let variables = try Self.newVariables(arguments, existing: [])
            let environment = RequestEnvironment(name: name, variables: variables)
            try context.mutate(project.id) { $0.environments.append(environment) }
            return .object(["environment": MCPDescriptions.environmentReference(environment)])
        }
    }

    private var updateEnvironment: MCPTool {
        MCPTool(
            "update_environment",
            title: "Rename environment",
            description: "Renames an environment. Default can't be renamed.",
            properties: [
                "project": MCPSchema.project,
                "environment": MCPSchema.string("The environment's ID or name."),
                "name": MCPSchema.string("Its new name.")
            ],
            required: ["project", "environment", "name"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let environment = try context.environment(try arguments.string("environment"), in: document)
            guard !document.isDefaultEnvironment(environment.id) else {
                throw MCPToolError("Default can't be renamed.")
            }
            let name = try arguments.string("name")
            if name.caseInsensitiveCompare(environment.name) != .orderedSame {
                try Self.requireUniqueName(name, in: document)
            }
            try context.mutate(project.id) { $0.updateEnvironment(environment.id) { $0.name = name } }
            return .object(["environment": ["id": .string(environment.id.description), "name": .string(name)]])
        }
    }

    private var deleteEnvironment: MCPTool {
        MCPTool(
            "delete_environment",
            title: "Delete environment",
            description: "Moves an environment's file to the Trash. Default can't be deleted; if the deleted one was active, "
                + "Default becomes active.",
            properties: ["project": MCPSchema.project, "environment": MCPSchema.string("The environment's ID or name.")],
            required: ["project", "environment"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let environment = try context.environment(try arguments.string("environment"), in: document)
            guard !document.isDefaultEnvironment(environment.id) else {
                throw MCPToolError("Default can't be deleted; every project keeps it.")
            }
            try context.mutate(project.id) { $0.environments.removeAll { $0.id == environment.id } }
            if context.workspace.projectState(project.id).activeEnvironmentID == environment.id {
                context.workspace.updateProject(project.id) { $0.activeEnvironmentID = nil }
            }
            return .object(["deleted": MCPDescriptions.environmentReference(environment)])
        }
    }

    private var setActiveEnvironment: MCPTool {
        MCPTool(
            "set_active_environment",
            title: "Set active environment",
            description: "Chooses the environment the window, and execute_request without an environment, use for a project.",
            properties: ["project": MCPSchema.project, "environment": MCPSchema.string("The environment's ID or name.")],
            required: ["project", "environment"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let environment = try context.environment(try arguments.string("environment"), in: document)
            context.workspace.updateProject(project.id) { $0.activeEnvironmentID = environment.id }
            return .object(["activeEnvironment": MCPDescriptions.environmentReference(environment)])
        }
    }

    // MARK: - Variables

    private var listVariables: MCPTool {
        MCPTool(
            "list_variables",
            title: "List variables",
            description: "An environment's variables. Secret variables show `secret: true` and never their value.",
            properties: [
                "project": MCPSchema.project,
                "environment": MCPSchema.variablesEnvironment,
                "includeAllEnvironments": MCPSchema.boolean("List every environment's variables instead, side by side.")
            ],
            required: ["project"],
            annotations: .read
        ) { arguments in
            let (_, document) = try context.document(try arguments.string("project"))
            if try arguments.bool("includeAllEnvironments", default: false) {
                return .object(["environments": .array(document.allEnvironments.map { environment in
                    [
                        "id": .string(environment.id.description),
                        "name": .string(environment.name),
                        "variables": .array(environment.variables.map(MCPDescriptions.variable))
                    ]
                })])
            }
            let environment = try context.environment(try arguments.optionalString("environment"), in: document)
            return .object([
                "environment": MCPDescriptions.environmentReference(environment),
                "variables": .array(environment.variables.map(MCPDescriptions.variable))
            ])
        }
    }

    private var createVariables: MCPTool {
        MCPTool(
            "create_variables",
            title: "Create variables",
            description: "Adds variables to an environment (Default unless named). Fails, adding none, if any key already exists "
                + "there; use update_variables to change one.",
            properties: [
                "project": MCPSchema.project,
                "environment": MCPSchema.variablesEnvironment,
                "variables": Self.newVariablesSchema
            ],
            required: ["project", "variables"],
            annotations: .create
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let environment = try context.environment(try arguments.optionalString("environment"), in: document)
            let variables = try Self.newVariables(arguments, existing: environment.variables)
            guard !variables.isEmpty else {
                throw MCPToolError("`variables` must list at least one variable.")
            }
            try context.mutate(project.id) { $0.updateEnvironment(environment.id) { $0.variables += variables } }
            return .object([
                "environment": MCPDescriptions.environmentReference(environment),
                "created": .array(variables.map(MCPDescriptions.variable))
            ])
        }
    }

    private var updateVariables: MCPTool {
        MCPTool(
            "update_variables",
            title: "Update variables",
            description: "Changes existing variables in an environment (Default unless named), by key: a new key, value, enabled "
                + "state, or secret flag. Omitted fields keep their value. Fails, changing none, if a key doesn't exist.",
            properties: [
                "project": MCPSchema.project,
                "environment": MCPSchema.variablesEnvironment,
                "variables": MCPSchema.array(MCPSchema.object([
                    "key": MCPSchema.string("The variable to change."),
                    "newKey": MCPSchema.string("Renames it."),
                    "value": MCPSchema.string("Its new value."),
                    "enabled": MCPSchema.boolean("Whether requests can use it."),
                    "secret": MCPSchema.boolean("Keep the value in the Keychain instead of the project's files.")
                ], required: ["key"]), "The changes.", minItems: 1)
            ],
            required: ["project", "variables"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let environment = try context.environment(try arguments.optionalString("environment"), in: document)
            let changes = try arguments.objects("variables", allowed: ["key", "newKey", "value", "enabled", "secret"]) ?? []
            var variables = environment.variables
            for change in changes {
                let key = try change.string("key")
                guard let index = variables.firstIndex(where: { $0.key == key }) else {
                    throw MCPToolError("\(environment.name) has no variable `\(key)`; create_variables adds one.")
                }
                if let newKey = try change.optionalString("newKey"), newKey != key {
                    guard !variables.contains(where: { $0.key == newKey }) else {
                        throw MCPToolError("\(environment.name) already has a variable `\(newKey)`.")
                    }
                    variables[index].key = newKey
                }
                if let value = try change.optionalRawString("value") {
                    variables[index].value = value
                }
                variables[index].isEnabled = try change.optionalBool("enabled") ?? variables[index].isEnabled
                variables[index].isSecret = try change.optionalBool("secret") ?? variables[index].isSecret
            }
            let updated = variables
            try context.mutate(project.id) { $0.updateEnvironment(environment.id) { $0.variables = updated } }
            return .object([
                "environment": MCPDescriptions.environmentReference(environment),
                "variables": .array(updated.map(MCPDescriptions.variable))
            ])
        }
    }

    private var deleteVariables: MCPTool {
        MCPTool(
            "delete_variables",
            title: "Delete variables",
            description: "Removes variables from an environment (Default unless named) by key, deleting any secret values. "
                + "Fails, removing none, if a key doesn't exist.",
            properties: [
                "project": MCPSchema.project,
                "environment": MCPSchema.variablesEnvironment,
                "keys": MCPSchema.array(["type": "string"], "The keys to remove.", minItems: 1)
            ],
            required: ["project", "keys"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            let environment = try context.environment(try arguments.optionalString("environment"), in: document)
            let keys = Set(try arguments.stringArray("keys") ?? [])
            let missing = keys.subtracting(environment.variables.map(\.key)).sorted()
            guard missing.isEmpty else {
                throw MCPToolError("\(environment.name) has no variable \(missing.map { "`\($0)`" }.joined(separator: ", ")).")
            }
            try context.mutate(project.id) { $0.updateEnvironment(environment.id) { $0.variables.removeAll { keys.contains($0.key) } } }
            return .object(["environment": MCPDescriptions.environmentReference(environment), "deleted": .array(keys.sorted().map(Value.string))])
        }
    }

    // MARK: - Helpers

    static let newVariablesSchema = MCPSchema.array(MCPSchema.object([
        "key": MCPSchema.string("The name requests use, as {{key}}."),
        "value": MCPSchema.string("Its value."),
        "enabled": MCPSchema.boolean("Whether requests can use it. Defaults to true."),
        "secret": MCPSchema.boolean("Keep the value in the Keychain instead of the project's files. Defaults to false.")
    ], required: ["key", "value"]), "Variables to add.")

    private static func newVariables(_ arguments: MCPArguments, existing: [Variable]) throws -> [Variable] {
        var keys = Set(existing.map(\.key))
        return try (arguments.objects("variables", allowed: ["key", "value", "enabled", "secret"]) ?? []).map { entry in
            let key = try entry.string("key")
            guard keys.insert(key).inserted else {
                throw MCPToolError("A variable `\(key)` already exists there; use update_variables to change it.")
            }
            return Variable(
                key: key,
                value: try entry.optionalRawString("value") ?? "",
                isEnabled: try entry.bool("enabled", default: true),
                isSecret: try entry.bool("secret", default: false)
            )
        }
    }

    private static func requireUniqueName(_ name: String, in document: ProjectDocument) throws {
        guard !document.allEnvironments.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw MCPToolError("“\(document.name)” already has an environment named “\(name)”.")
        }
    }
}
