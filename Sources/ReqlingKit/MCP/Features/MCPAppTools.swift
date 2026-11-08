import Foundation
import MCP

/// The app itself: what the window shows, bringing an item into view, and the preferences agents may change. The MCP
/// server's own settings and token are not among them; only the person at the Mac changes those.
@MainActor
struct MCPAppTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [getAppState, revealItem, getSettings, updateSettings, getUpdateStatus, checkForUpdates]
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
            description: "Reqling's preferences: theme, HTTP request defaults, the gRPC deadline, the scripts' time limit, the "
                + "protoc path override, and how long and how much run history stays on this Mac.",
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
                "scriptTimeLimitSeconds": MCPSchema.number(
                    "How long each phase of a request's scripts, and each call of a stream script's handlers, may run before it's stopped.",
                    minimum: AppSettings.scriptTimeLimitRange.lowerBound,
                    maximum: AppSettings.scriptTimeLimitRange.upperBound
                ),
                "protocPath": MCPSchema.string("A protoc to compile with instead of searching for one. Empty clears it."),
                "historyRetention": MCPSchema.enumeration(
                    HistoryRetention.allCases.map(\.rawValue),
                    "How long runs stay in history; each request's latest stays until the size limit needs its space."
                ),
                "historySizeLimit": MCPSchema.enumeration(
                    HistorySizeLimit.allCases.map(\.rawValue),
                    "The most space every request's runs may take together; the oldest go first."
                )
            ],
            annotations: .edit
        ) { arguments in
            let theme = try Self.choice(arguments, "theme", AppTheme.self)
            let timeout = try arguments.optionalNumber("requestTimeoutSeconds", in: AppSettings.timeoutRange)
            let deadline = try arguments.optionalNumber("grpcDeadlineSeconds", in: AppSettings.timeoutRange)
            let scriptTimeLimit = try arguments.optionalNumber("scriptTimeLimitSeconds", in: AppSettings.scriptTimeLimitRange)
            let followRedirects = try arguments.optionalBool("followRedirects")
            let verifyTLS = try arguments.optionalBool("verifyTLS")
            let protocPath = try arguments.optionalRawString("protocPath")
            let retention = try Self.choice(arguments, "historyRetention", HistoryRetention.self)
            let sizeLimit = try Self.choice(arguments, "historySizeLimit", HistorySizeLimit.self)
            context.settings.update { settings in
                settings.theme = theme ?? settings.theme
                settings.requestTimeoutSeconds = timeout ?? settings.requestTimeoutSeconds
                settings.grpcDeadlineSeconds = deadline ?? settings.grpcDeadlineSeconds
                settings.scriptTimeLimitSeconds = scriptTimeLimit ?? settings.scriptTimeLimitSeconds
                settings.followRedirects = followRedirects ?? settings.followRedirects
                settings.verifyTLS = verifyTLS ?? settings.verifyTLS
                if let protocPath {
                    settings.protocPath = protocPath
                }
                settings.historyRetention = retention ?? settings.historyRetention
                settings.historySizeLimit = sizeLimit ?? settings.historySizeLimit
            }
            if retention != nil || sizeLimit != nil {
                context.runner.history.prune()
            }
            if protocPath != nil {
                // A changed override reaches no file watcher, so every workspace recompiles with the protoc it now finds.
                context.protoWorkspaces.recompileAll()
            }
            return .object(Self.describe(context.settings.settings))
        }
    }

    // MARK: - Updates

    private var getUpdateStatus: MCPTool {
        MCPTool(
            "get_update_status",
            title: "Get update status",
            description: "The running Reqling version, the last check's result, and whether an update is downloading or "
                + "ready. Installing one is the user's choice, in Settings ▸ App Updates.",
            annotations: .read
        ) { _ in
            .object(try Self.describe(updates()))
        }
    }

    private var checkForUpdates: MCPTool {
        MCPTool(
            "check_for_updates",
            title: "Check for updates",
            description: "Asks GitHub for a newer Reqling now and returns the result, as get_update_status describes it.",
            annotations: .networkRead,
            timeout: .seconds(60)
        ) { _ in
            let updates = try updates()
            await updates.forceCheck()
            return .object(Self.describe(updates))
        }
    }

    private func updates() throws -> AppUpdateManager {
        guard let updates = context.updates else {
            throw MCPToolError("This build of Reqling doesn't check for updates.")
        }
        return updates
    }

    private static func describe(_ updates: AppUpdateManager) -> [String: Value] {
        var description: [String: Value] = [
            "currentVersion": updates.currentVersionString.map(Value.string) ?? .null,
            "lastCheckedAt": updates.lastCheckedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null
        ]
        switch updates.status {
        case .idle:
            description["status"] = "notChecked"
        case .upToDate:
            description["status"] = "upToDate"
        case .updateAvailable(let release, _):
            description["status"] = "updateAvailable"
            description["availableVersion"] = .string(release.version.description)
            description["releaseURL"] = .string(release.htmlURL.absoluteString)
        case .unavailable(let reason):
            description["status"] = "unavailable"
            description["reason"] = .string(reason.message)
        }
        if let staged = updates.stagedUpdate {
            description["readyToInstall"] = .string(staged.release.version.description)
        }
        if case .downloading(_, let progress) = updates.downloadState {
            description["downloadProgress"] = .double(progress)
        }
        return description
    }

    private static func describe(_ settings: AppSettings) -> [String: Value] {
        [
            "theme": .string(settings.theme.rawValue),
            "requestTimeoutSeconds": .double(settings.requestTimeoutSeconds),
            "followRedirects": .bool(settings.followRedirects),
            "verifyTLS": .bool(settings.verifyTLS),
            "grpcDeadlineSeconds": .double(settings.grpcDeadlineSeconds),
            "scriptTimeLimitSeconds": .double(settings.scriptTimeLimitSeconds),
            "protocPath": settings.protocPath.map(Value.string) ?? .null,
            "historyRetention": .string(settings.historyRetention.rawValue),
            "historySizeLimit": .string(settings.historySizeLimit.rawValue)
        ]
    }

    /// A string argument naming one of `Choice`'s cases.
    private static func choice<Choice: RawRepresentable & CaseIterable>(
        _ arguments: MCPArguments,
        _ key: String,
        _ type: Choice.Type
    ) throws -> Choice? where Choice.RawValue == String {
        try arguments.optionalString(key).map { name in
            guard let choice = Choice(rawValue: name) else {
                throw MCPToolError("`\(key)` must be one of \(Choice.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return choice
        }
    }
}
