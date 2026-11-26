#if DEBUG
import CloudKit
import CryptoKit
import Foundation
import MCP
import ReqlingTemplating

/// The end-to-end harness's sharing of real projects (`SharingHarness`), listed only on a debug build launched as the
/// harness (`MCPToolContext.sharingHarness`), for `scripts/sharing-e2e.sh run` to drive the same scenarios on both
/// Macs. Leaving and deleting take the window's path (`ProjectLifecycle.deleteProject`), which `delete_project`
/// refuses for a shared project. Nothing here returns a secret value; `harness_state` gives a short digest of each.
@MainActor
struct MCPSharingHarnessTools {
    let context: MCPToolContext
    let harness: SharingHarness

    var tools: [MCPTool] {
        [share, removeParticipant, stopSharing, accept, deleteProject, setSecretValues, setCurrentValues, sync, state, reset]
    }

    private static let values = MCPSchema.stringMap("Values by variable key, in the project's Default environment.")

    private var share: MCPTool {
        MCPTool(
            "harness_share",
            title: "Harness: share a project",
            description: "Shares one of this account's projects as Share… does, then invites someone or sets the link. Returns its URL.",
            properties: [
                "project": MCPSchema.project,
                "invite": MCPSchema.string("The email address of an Apple Account to invite, or to change if invited already."),
                "permission": MCPSchema.enumeration(["readOnly", "readWrite"], "The invited person's permission."),
                "canInvite": MCPSchema.boolean("Whether the invited person may invite others."),
                "link": MCPSchema.enumeration(["none", "readOnly", "readWrite"], "Who may join by the link alone.")
            ],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            guard project.sharing == nil else {
                throw MCPToolError("\(project.name) is someone else's; only its owner shares it from here.")
            }
            // As Share… is: a project shares only once it syncs, since its share lives in its zone.
            if case .unavailable(let reason)? = context.sync?.shareAction(for: project.id) {
                throw MCPToolError(reason)
            }
            let url = try await harness.share(
                project.id,
                invite: try MCPHarnessTools.invitation(arguments),
                link: try MCPHarnessTools.permission(arguments, "link")
            )
            return .object(["url": .string(url)])
        }
    }

    private var removeParticipant: MCPTool {
        MCPTool(
            "harness_remove_participant",
            title: "Harness: remove someone",
            description: "Removes someone, by email address, from a project this account shares.",
            properties: ["project": MCPSchema.project, "email": MCPSchema.string("Their Apple Account's email address.")],
            required: ["project", "email"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            let email = try arguments.string("email")
            return try await Self.failingWithCloudKit { try await harness.removeParticipant(email, from: project.id) }
        }
    }

    private var stopSharing: MCPTool {
        MCPTool(
            "harness_stop_sharing",
            title: "Harness: stop sharing",
            description: "Stops sharing a project this account shares, for everyone.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            return try await Self.failingWithCloudKit { try await harness.stopSharing(project.id) }
        }
    }

    private var accept: MCPTool {
        MCPTool(
            "harness_accept",
            title: "Harness: open a share's link",
            description: "Accepts the share a link names, as opening it does, then syncs. Returns the project's ID.",
            properties: ["url": MCPSchema.string("The share's URL, as harness_share returned it.")],
            required: ["url"],
            annotations: .create,
            timeout: .seconds(120)
        ) { arguments in
            guard let url = URL(string: try arguments.string("url")) else {
                throw MCPToolError("url isn't a URL.")
            }
            let accepted = try await harness.accept(url)
            return .object(["project": .string(accepted.project.description), "title": accepted.title.map(Value.string) ?? .null])
        }
    }

    private var deleteProject: MCPTool {
        MCPTool(
            "harness_delete_project",
            title: "Harness: Move to Trash or Leave",
            description: "Deletes a project as the window does: one of this account's own goes for everyone it's shared with; "
                + "someone else's is left, and only this copy goes to the Trash.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            try context.lifecycle.deleteProject(project.id)
            return .object(["result": "ok"])
        }
    }

    private var setSecretValues: MCPTool {
        MCPTool(
            "harness_set_secret_values",
            title: "Harness: set my secret values",
            description: "Sets this person's own values for secret variables, as the Environments sheet does, even where they may only view.",
            properties: ["project": MCPSchema.project, "values": Self.values],
            required: ["project", "values"],
            annotations: .edit
        ) { arguments in
            let (project, environment) = try defaultEnvironment(try arguments.string("project"))
            var secrets: [String: String] = [:]
            for (key, value) in try arguments.stringMap("values") ?? [:] {
                guard let variable = environment.variables.first(where: { $0.key == key && $0.isSecret }) else {
                    throw MCPToolError("Default has no secret variable \(key).")
                }
                secrets[SecretKey.variable(variable.id, in: environment.id)] = value
            }
            try context.library.setSecretValues(secrets, in: project.id)
            return .object(["result": "ok"])
        }
    }

    private var setCurrentValues: MCPTool {
        MCPTool(
            "harness_set_current_values",
            title: "Harness: set current values",
            description: "Sets current values as a script would, without running one, so no run trusts a script.",
            properties: ["project": MCPSchema.project, "values": Self.values],
            required: ["project", "values"],
            annotations: .edit
        ) { arguments in
            let (project, environment) = try defaultEnvironment(try arguments.string("project"))
            let values = try arguments.stringMap("values") ?? [:]
            let scope = CurrentValueScope.environment(project.id, environment.id)
            context.library.currentValues.apply(values.mapValues { .value(TemplateVariable(value: $0)) }, in: scope)
            return .object(["result": "ok"])
        }
    }

    private var sync: MCPTool {
        MCPTool(
            "harness_sync",
            title: "Harness: sync now",
            description: "Sends what's pending and fetches what CloudKit has flagged, which on macOS is only what a push, or "
                + "this copy becoming active, flagged. Returns how sync stands.",
            annotations: .edit,
            timeout: .seconds(120)
        ) { _ in
            guard let sync = context.sync else {
                throw MCPToolError("iCloud sync isn't running.")
            }
            await sync.syncNow()
            return .object(Self.describe(sync))
        }
    }

    private var state: MCPTool {
        MCPTool(
            "harness_state",
            title: "Harness: state",
            description: "Every project as this copy holds it, with digests of secret and current values, never the values.",
            annotations: .read
        ) { _ in
            var description = context.sync.map(Self.describe) ?? [:]
            description["projects"] = .array(context.library.projects.map { describe($0) })
            return .object(description)
        }
    }

    private var reset: MCPTool {
        MCPTool(
            "harness_reset",
            title: "Harness: reset iCloud",
            description: "Deletes every zone this account owns in the harness's container and leaves every share it takes part in.",
            annotations: .destroy,
            timeout: .seconds(120)
        ) { _ in
            let (deleted, left) = try await harness.resetCloud()
            return .object(["deletedZones": .int(deleted), "leftShares": .int(left)])
        }
    }

    // MARK: - Helpers

    private func defaultEnvironment(_ reference: String) throws -> (LibraryProject, RequestEnvironment) {
        let project = try context.project(reference)
        guard let document = project.document else {
            throw MCPToolError("\(project.name) didn't load.")
        }
        return (project, document.defaultEnvironment)
    }

    /// `ok`, or a failure naming CloudKit's error, unlike a probe's `outcome`: a scenario expects every step to work, so
    /// one that doesn't stops it there rather than leaving it to time out waiting on what never happened.
    private static func failingWithCloudKit(_ body: () async throws -> Void) async throws -> MCPToolResult {
        do {
            try await body()
        } catch {
            throw MCPToolError(CloudKitProbe.describe(error))
        }
        return .object(["result": "ok"])
    }

    private static func describe(_ sync: LibrarySync) -> [String: Value] {
        let status: String = switch sync.status {
        case .upToDate: "upToDate"
        case .failed(let message): "failed: \(message)"
        default: "\(sync.status)"
        }
        return ["status": .string(status), "issues": .array(sync.issues.map(Value.string))]
    }

    /// What the scenarios compare across both Macs: a project's requests and saved values, which converge, and each
    /// person's own values, by digest, which must never cross.
    private func describe(_ project: LibraryProject) -> Value {
        var description: [String: Value] = [
            "id": .string(project.id.description),
            "name": .string(project.name),
            "readOnly": .bool(project.isReadOnly)
        ]
        if let sharing = project.sharing {
            description["sharing"] = .object([
                "owner": .string(sharing.owner),
                "permission": .string(sharing.permission == .readOnly ? "readOnly" : "readWrite"),
                "canInvite": .bool(sharing.canInvite)
            ])
        }
        switch context.sync?.shareAction(for: project.id) {
        case .share?: description["shareAction"] = "share"
        case .manage?: description["shareAction"] = "manage"
        case .unavailable?: description["shareAction"] = "unavailable"
        case nil: break
        }
        if let audience = context.sync?.sharedByYou[project.id] {
            description["sharedByYou"] = .object(["people": .int(audience.people), "byLink": .bool(audience.byLink)])
        }
        guard let document = project.document else {
            return .object(description)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let requests = document.allRequests.map(\.request).sorted { $0.name < $1.name }.map { request in
            Value.object(["name": .string(request.name), "digest": .string(Self.digest((try? encoder.encode(request)) ?? Data()))])
        }
        let environment = document.defaultEnvironment
        let variables = environment.variables.sorted { $0.key < $1.key }.map { variable in
            let value: Value = if !variable.isSecret {
                .string(variable.value)
            } else {
                variable.value.isEmpty ? .null : .string("sha:" + Self.digest(Data(variable.value.utf8)))
            }
            return Value.object(["key": .string(variable.key), "secret": .bool(variable.isSecret), "value": value])
        }
        let current = context.library.currentValues.values(in: .environment(project.id, environment.id))
        description["requests"] = .array(requests)
        description["variables"] = .array(variables)
        description["currentValues"] = .object(current.mapValues { value in
            if case .value(let variable) = value {
                return .string("sha:" + Self.digest(Data(variable.value.utf8)))
            }
            return .string("unset")
        })
        return .object(description)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
