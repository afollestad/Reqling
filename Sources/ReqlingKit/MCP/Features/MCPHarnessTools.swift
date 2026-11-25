#if DEBUG
import CloudKit
import Foundation
import MCP

/// The end-to-end harness's raw CloudKit probes (`CloudKitProbe`), listed only on a debug build launched as the
/// harness (`MCPToolContext.probe`), never on one a person uses. `scripts/sharing-e2e.sh` drives them on both Macs.
@MainActor
struct MCPHarnessTools {
    let probe: CloudKitProbe

    var tools: [MCPTool] {
        [identity, share, updateShare, removeParticipant, stopSharing, deleteZone, reset, accept, leave, write, read, changes]
    }

    private static let zone = MCPSchema.string("A probe zone's name, as `probe_share` returned it.")
    private static let owner = MCPSchema.string("The zone owner's user record name, for a zone shared with this account; omit for its own.")
    private static let permission = MCPSchema.enumeration(["none", "readOnly", "readWrite"], "A permission.")
    private static let invite: [String: Value] = [
        "invite": MCPSchema.string("The email address of an Apple Account to add as a participant."),
        "permission": MCPSchema.enumeration(["readOnly", "readWrite"], "The invited participant's permission."),
        "canInvite": MCPSchema.boolean("Whether the invited participant is an administrator, who may invite others.")
    ]

    private var identity: MCPTool {
        MCPTool(
            "probe_identity",
            title: "Probe: identity",
            description: "This Mac's iCloud account status and user record name.",
            annotations: .read
        ) { _ in
            .object(try await probe.identity().mapValues(Value.string))
        }
    }

    private var share: MCPTool {
        MCPTool(
            "probe_share",
            title: "Probe: share a zone",
            description: "Creates a probe zone holding one record and shares the whole zone. Returns its name and URL.",
            properties: Self.invite.merging(["publicPermission": Self.permission]) { first, _ in first },
            annotations: .create
        ) { arguments in
            let shared = try await probe.share(
                publicPermission: try Self.permission(arguments, "publicPermission") ?? .none,
                invite: try Self.invitation(arguments)
            )
            return .object(shared.mapValues(Value.string))
        }
    }

    private var updateShare: MCPTool {
        MCPTool(
            "probe_update_share",
            title: "Probe: change a share",
            description: "Changes a zone's share: its public permission, or a participant to add. Returns the server's answer.",
            properties: Self.invite.merging(["zone": Self.zone, "owner": Self.owner, "publicPermission": Self.permission]) { first, _ in first },
            required: ["zone"],
            annotations: .edit
        ) { arguments in
            await Self.outcome {
                try await probe.updateShare(
                    zone: try arguments.string("zone"),
                    owner: try arguments.optionalString("owner"),
                    publicPermission: try Self.permission(arguments, "publicPermission"),
                    invite: try Self.invitation(arguments)
                )
            }
        }
    }

    private var removeParticipant: MCPTool {
        MCPTool(
            "probe_remove_participant",
            title: "Probe: remove a participant",
            description: "Removes a participant, by email address, from a zone this account owns.",
            properties: ["zone": Self.zone, "email": MCPSchema.string("The participant's email address.")],
            required: ["zone", "email"],
            annotations: .edit
        ) { arguments in
            await Self.outcome { try await probe.removeParticipant(zone: try arguments.string("zone"), email: try arguments.string("email")) }
        }
    }

    private var stopSharing: MCPTool {
        MCPTool(
            "probe_stop_sharing",
            title: "Probe: stop sharing",
            description: "Deletes the share of a zone this account owns.",
            properties: ["zone": Self.zone],
            required: ["zone"],
            annotations: .edit
        ) { arguments in
            await Self.outcome { try await probe.stopSharing(zone: try arguments.string("zone")) }
        }
    }

    private var deleteZone: MCPTool {
        MCPTool(
            "probe_delete_zone",
            title: "Probe: delete a zone",
            description: "Deletes a probe zone this account owns.",
            properties: ["zone": Self.zone],
            required: ["zone"],
            annotations: .destroy
        ) { arguments in
            await Self.outcome { try await probe.deleteZone(try arguments.string("zone")) }
        }
    }

    private var reset: MCPTool {
        MCPTool("probe_reset", title: "Probe: reset", description: "Deletes every probe zone this account owns.", annotations: .destroy) { _ in
            .object(["deleted": .int(try await probe.reset())])
        }
    }

    private var accept: MCPTool {
        MCPTool(
            "probe_accept",
            title: "Probe: accept a share",
            description: "Accepts a share by its URL. Returns the zone, its owner, and this account's role and permission.",
            properties: ["url": MCPSchema.string("The share's URL.")],
            required: ["url"],
            annotations: .edit
        ) { arguments in
            guard let url = URL(string: try arguments.string("url")) else {
                throw MCPToolError("url isn't a URL.")
            }
            return .object(try await probe.accept(url).mapValues(Value.string))
        }
    }

    private var leave: MCPTool {
        MCPTool(
            "probe_leave",
            title: "Probe: leave a share",
            description: "Leaves a zone shared with this account.",
            properties: ["zone": Self.zone, "owner": Self.owner],
            required: ["zone", "owner"],
            annotations: .edit
        ) { arguments in
            await Self.outcome { try await probe.leave(zone: try arguments.string("zone"), owner: try arguments.string("owner")) }
        }
    }

    private var write: MCPTool {
        MCPTool(
            "probe_write",
            title: "Probe: write a record",
            description: "Saves a new record into a probe zone. Returns `saved`, or the server's error.",
            properties: ["zone": Self.zone, "owner": Self.owner],
            required: ["zone"],
            annotations: .create
        ) { arguments in
            .object(["result": .string(await probe.write(zone: try arguments.string("zone"), owner: try arguments.optionalString("owner")))])
        }
    }

    private var read: MCPTool {
        MCPTool(
            "probe_read",
            title: "Probe: read a zone",
            description: "Each record in a probe zone, and whether its encrypted field could be read.",
            properties: ["zone": Self.zone, "owner": Self.owner],
            required: ["zone"],
            annotations: .read
        ) { arguments in
            let records = try await probe.read(zone: try arguments.string("zone"), owner: try arguments.optionalString("owner"))
            return .object(["records": .array(records.map { .object($0.mapValues(Value.string)) })])
        }
    }

    private var changes: MCPTool {
        MCPTool(
            "probe_changes",
            title: "Probe: changes",
            description: "What changed in a database since the last call: probe zones changed and deleted, with reasons, and their records.",
            properties: ["database": MCPSchema.enumeration(["private", "shared"], "Which database.")],
            required: ["database"],
            annotations: .read
        ) { arguments in
            let scope: CKDatabase.Scope = try arguments.string("database") == "shared" ? .shared : .private
            let changes = try await probe.changes(in: scope)
            return .object(changes.mapValues { .array($0.map { .object($0.mapValues(Value.string)) }) })
        }
    }

    // MARK: - Arguments

    private static func permission(_ arguments: MCPArguments, _ key: String) throws -> CKShare.ParticipantPermission? {
        switch try arguments.optionalString(key) {
        case nil: nil
        case "none": CKShare.ParticipantPermission.none
        case "readOnly": .readOnly
        case "readWrite": .readWrite
        case let other?: throw MCPToolError("\(key) must be none, readOnly, or readWrite, not \(other).")
        }
    }

    private static func invitation(_ arguments: MCPArguments) throws -> CloudKitProbe.Invitation? {
        guard let email = try arguments.optionalString("invite") else {
            return nil
        }
        return CloudKitProbe.Invitation(
            email: email,
            permission: try permission(arguments, "permission") ?? .readOnly,
            role: try arguments.bool("canInvite", default: false) ? .administrator : .privateUser
        )
    }

    /// `ok`, or the server's refusal, as a result rather than an error, since a refusal is what a probe looks for.
    private static func outcome(_ body: () async throws -> Void) async -> MCPToolResult {
        do {
            try await body()
            return .object(["result": "ok"])
        } catch {
            return .object(["result": .string(CloudKitProbe.describe(error))])
        }
    }
}
#endif
