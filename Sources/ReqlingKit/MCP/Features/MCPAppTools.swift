import Foundation
import MCP

/// The app itself: what the window shows, bringing an item into view, and the preferences agents may change. The MCP
/// server's own settings and token are not among them; only the person at the Mac changes those.
@MainActor
struct MCPAppTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [getAppState, revealItem, getSettings, updateSettings]
    }

    private var getAppState: MCPTool {
        MCPTool(
            "get_app_state",
            title: "Get app state",
            description: "Reqling's version, how many projects are open, and what is selected in the window.",
            annotations: .read
        ) { _ in
            var state: [String: Value] = [
                "app": [
                    "name": .string(context.appInfo.name),
                    "version": .string(context.appInfo.version),
                    "build": .string(context.appInfo.build)
                ],
                "projectCount": .int(context.library.projects.count),
                "selection": .null
            ]
            if let selected = context.host?.selectedItem, let project = context.library.project(selected.project) {
                var selection: [String: Value] = ["project": .string(project.id.description), "projectName": .string(project.name)]
                if let id = selected.node, let node = project.document?.node(id) {
                    selection["item"] = .string(id.description)
                    selection["itemName"] = .string(node.name)
                    selection["itemKind"] = node.isFolder ? "folder" : "request"
                }
                state["selection"] = .object(selection)
            }
            return .object(state)
        }
    }

    private var revealItem: MCPTool {
        MCPTool(
            "reveal_item",
            title: "Show in Reqling",
            description: "Selects a project, folder, or request in Reqling's sidebar and brings the window forward, so the person "
                + "at the Mac sees it.",
            properties: [
                "project": MCPSchema.project,
                "item": MCPSchema.string("A request's or folder's ID. Omit to show the project itself.")
            ],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            var node: RequestNodeID?
            if let reference = try arguments.optionalString("item") {
                guard let id = RequestNodeID(string: reference), document.node(id) != nil else {
                    throw MCPToolError("“\(document.name)” has no item with ID \(reference).")
                }
                node = id
            }
            guard let host = context.host else {
                throw MCPToolError("Reqling's window isn't open.")
            }
            host.reveal(project.id, node: node)
            return .object(["revealed": .string(node?.description ?? project.id.description)])
        }
    }

    private var getSettings: MCPTool {
        MCPTool(
            "get_settings",
            title: "Get settings",
            description: "Reqling's preferences: theme, HTTP request defaults, the gRPC deadline, and the protoc path override.",
            annotations: .read
        ) { _ in
            .object(Self.describe(context.settings.settings))
        }
    }

    private var updateSettings: MCPTool {
        MCPTool(
            "update_settings",
            title: "Update settings",
            description: "Changes Reqling's preferences. Omitted fields keep their value; requests can override the HTTP and gRPC "
                + "defaults one by one.",
            properties: [
                "theme": MCPSchema.enumeration(AppTheme.allCases.map(\.rawValue), "The window's appearance."),
                "requestTimeoutSeconds": MCPSchema.number("The default HTTP timeout.", minimum: 1, maximum: 600),
                "followRedirects": MCPSchema.boolean("Whether HTTP requests follow redirects by default."),
                "verifyTLS": MCPSchema.boolean("Whether requests verify servers' TLS certificates by default."),
                "grpcDeadlineSeconds": MCPSchema.number("The default gRPC deadline.", minimum: 1, maximum: 600),
                "protocPath": MCPSchema.string("A protoc to compile with instead of searching for one. Empty clears it.")
            ],
            annotations: .edit
        ) { arguments in
            let theme = try arguments.optionalString("theme").map { name in
                guard let theme = AppTheme(rawValue: name) else {
                    throw MCPToolError("`theme` must be one of \(AppTheme.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                return theme
            }
            let timeout = try arguments.optionalNumber("requestTimeoutSeconds", in: AppSettings.timeoutRange)
            let deadline = try arguments.optionalNumber("grpcDeadlineSeconds", in: AppSettings.timeoutRange)
            let followRedirects = try arguments.optionalBool("followRedirects")
            let verifyTLS = try arguments.optionalBool("verifyTLS")
            let protocPath = try arguments.optionalRawString("protocPath")
            context.settings.update { settings in
                settings.theme = theme ?? settings.theme
                settings.requestTimeoutSeconds = timeout ?? settings.requestTimeoutSeconds
                settings.grpcDeadlineSeconds = deadline ?? settings.grpcDeadlineSeconds
                settings.followRedirects = followRedirects ?? settings.followRedirects
                settings.verifyTLS = verifyTLS ?? settings.verifyTLS
                if let protocPath {
                    settings.protocPath = protocPath
                }
            }
            if protocPath != nil {
                // A changed override reaches no file watcher, so every workspace recompiles with the protoc it now finds.
                context.protoWorkspaces.recompileAll()
            }
            return .object(Self.describe(context.settings.settings))
        }
    }

    private static func describe(_ settings: AppSettings) -> [String: Value] {
        [
            "theme": .string(settings.theme.rawValue),
            "requestTimeoutSeconds": .double(settings.requestTimeoutSeconds),
            "followRedirects": .bool(settings.followRedirects),
            "verifyTLS": .bool(settings.verifyTLS),
            "grpcDeadlineSeconds": .double(settings.grpcDeadlineSeconds),
            "protocPath": settings.protocPath.map(Value.string) ?? .null
        ]
    }
}
