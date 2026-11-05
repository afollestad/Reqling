import Foundation
import MCP

/// A project's client certificates (mutual TLS) and extra CA certificates, shared by its HTTP and gRPC requests.
/// Passphrases go to the Keychain and are never returned.
@MainActor
struct MCPTLSTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [getTLSConfig, updateTLSConfig]
    }

    private var getTLSConfig: MCPTool {
        MCPTool(
            "get_tls_config",
            title: "Get TLS settings",
            description: "A project's client certificates, each matched to hosts by pattern, and the CA certificates it trusts "
                + "besides the system's. Passphrases are never returned; `hasPassphrase` says whether one is stored.",
            properties: ["project": MCPSchema.project],
            required: ["project"],
            annotations: .read
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            return .object(describe(document.tls, in: project.id))
        }
    }

    private var updateTLSConfig: MCPTool {
        let path: Value = MCPSchema.object([
            "path": MCPSchema.string("Relative to the project folder (shared with everyone who has the project), or absolute."),
            "local": MCPSchema.boolean("Keep an absolute path on this Mac only instead of in the project's files.")
        ], required: ["path"])
        return MCPTool(
            "update_tls_config",
            title: "Update TLS settings",
            description: "Sets a project's client certificates and CA certificates. Each list given replaces the current one, so "
                + "list existing certificates by `id` to keep them; omitted lists stay. A new client certificate needs a PKCS#12 "
                + "`file` (.p12/.pfx), or a PEM `certificate` and its `key` (the same path when one file holds both); Keychain "
                + "identities can only be chosen in Reqling's window, and are kept by `id`.",
            properties: [
                "project": MCPSchema.project,
                "clientCertificates": MCPSchema.array(MCPSchema.object([
                    "id": MCPSchema.string("An existing certificate's ID, to keep or change it."),
                    "hostPattern": MCPSchema.string("Hosts it is presented to: api.example.com, *.internal, or host:8443."),
                    "file": path,
                    "certificate": path,
                    "key": path,
                    "passphrase": MCPSchema.string(
                        "The PKCS#12 or encrypted key passphrase, stored in the Keychain. Empty removes it; omit to keep it."
                    )
                ]), "Client certificates; the most specific matching pattern wins for each host."),
                "caCertificates": MCPSchema.array(path, "PEM or DER CA certificates trusted besides the system's.")
            ],
            required: ["project"],
            annotations: .edit
        ) { arguments in
            let (project, document) = try context.document(try arguments.string("project"))
            var tls = document.tls
            var passphrases: [CertificateEntryID: String?] = [:]
            let allowed: Set<String> = ["id", "hostPattern", "file", "certificate", "key", "passphrase"]
            if let entries = try arguments.objects("clientCertificates", allowed: allowed) {
                tls.clientCertificates = try entries.map { entry in
                    try certificate(entry, existing: document.tls.clientCertificates, in: project, passphrases: &passphrases)
                }
                let kept = Set(tls.clientCertificates.map(\.id))
                guard kept.count == tls.clientCertificates.count else {
                    throw MCPToolError("`clientCertificates` lists one certificate's `id` more than once.")
                }
                for removed in document.tls.clientCertificates.map(\.id) where !kept.contains(removed) {
                    passphrases.updateValue(nil, forKey: removed)
                    context.workspace.setKeychainIdentity(nil, for: removed)
                }
            }
            if let authorities = try arguments.objects("caCertificates", allowed: ["path", "local"]) {
                tls.caCertificates = try authorities.map { try context.pathReference($0, in: project, existing: document.tls.caCertificates) }
            }
            let updated = tls
            try context.mutate(project.id) { $0.tls = updated }
            if !passphrases.isEmpty {
                do {
                    try context.library.updateCertificatePassphrases(passphrases, in: project.id)
                } catch {
                    throw MCPToolError("The certificates were saved, but the Keychain refused the passphrases: \(error.localizedDescription)")
                }
            }
            return .object(describe(updated, in: project.id))
        }
    }

    /// One certificate from its arguments, recording a passphrase change for the Keychain write after the save.
    private func certificate(
        _ entry: MCPArguments,
        existing: [ClientCertificateEntry],
        in project: LibraryProject,
        passphrases: inout [CertificateEntryID: String?]
    ) throws -> ClientCertificateEntry {
        var certificate: ClientCertificateEntry
        if let id = try entry.optionalString("id") {
            guard let match = existing.first(where: { $0.id.description == id.lowercased() }) else {
                throw MCPToolError("\(entry.path).id: the project has no client certificate \(id).")
            }
            certificate = match
        } else {
            guard entry.contains("file") || entry.contains("certificate") || entry.contains("key") else {
                throw MCPToolError(
                    "\(entry.path) needs a `file` (a .p12 or .pfx), or a PEM `certificate` and `key`, for a new certificate."
                )
            }
            certificate = ClientCertificateEntry(hostPattern: "", source: .keychainIdentity)
        }
        if let pattern = try entry.optionalString("hostPattern") {
            certificate.hostPattern = pattern
        }
        guard !certificate.hostPattern.isEmpty else {
            throw MCPToolError("\(entry.path).hostPattern is required for a new certificate.")
        }
        if let source = try source(entry, replacing: certificate.source, in: project) {
            if certificate.source == .keychainIdentity {
                context.workspace.setKeychainIdentity(nil, for: certificate.id)
            }
            certificate.source = source
        }
        if let passphrase = try entry.optionalRawString("passphrase") {
            passphrases.updateValue(passphrase.isEmpty ? nil : passphrase, forKey: certificate.id)
        }
        return certificate
    }

    /// The source `entry`'s files name, or `nil` when it names none. A PEM entry may replace just its `certificate` or
    /// its `key`; any other entry switching to PEM needs both. Local paths it already had keep their IDs.
    private func source(
        _ entry: MCPArguments,
        replacing current: ClientCertificateSource,
        in project: LibraryProject
    ) throws -> ClientCertificateSource? {
        let file = try entry.nested("file", allowed: ["path", "local"])
        let certificate = try entry.nested("certificate", allowed: ["path", "local"])
        let key = try entry.nested("key", allowed: ["path", "local"])
        var previous = current.files
        if let file {
            guard certificate == nil, key == nil else {
                throw MCPToolError("\(entry.path) takes a PKCS#12 `file` or a PEM `certificate` and `key`, not both.")
            }
            return .pkcs12(try context.pathReference(file, in: project, existing: previous))
        }
        guard certificate != nil || key != nil else {
            return nil
        }
        let currentPair: (certificate: ProjectPathReference, key: ProjectPathReference)?
        if case .pem(let currentCertificate, let currentKey) = current {
            currentPair = (currentCertificate, currentKey)
        } else {
            currentPair = nil
        }
        func reference(_ argument: MCPArguments?, otherwise kept: ProjectPathReference?) throws -> ProjectPathReference {
            guard let argument else {
                guard let kept else {
                    throw MCPToolError("\(entry.path) needs both a PEM `certificate` and its `key`.")
                }
                return kept
            }
            let reference = try context.pathReference(argument, in: project, existing: previous)
            previous.append(reference)
            return reference
        }
        return .pem(
            certificate: try reference(certificate, otherwise: currentPair?.certificate),
            key: try reference(key, otherwise: currentPair?.key)
        )
    }

    private func describe(_ tls: ProjectTLSConfiguration, in project: ProjectID) -> [String: Value] {
        [
            "clientCertificates": .array(tls.clientCertificates.map { entry in
                var description: [String: Value] = [
                    "id": .string(entry.id.description),
                    "hostPattern": .string(entry.hostPattern),
                    "hasPassphrase": .bool(context.library.certificatePassphrase(for: entry.id, in: project) != nil)
                ]
                switch entry.source {
                case .pkcs12(let reference):
                    description["source"] = "pkcs12"
                    description["file"] = context.describePath(reference, in: project)
                case .pem(let certificate, let key):
                    description["source"] = "pem"
                    description["certificate"] = context.describePath(certificate, in: project)
                    description["key"] = context.describePath(key, in: project)
                case .keychainIdentity:
                    description["source"] = "keychainIdentity"
                    description["chosenOnThisMac"] = .bool(context.workspace.keychainIdentity(for: entry.id) != nil)
                }
                return .object(description)
            }),
            "caCertificates": .array(tls.caCertificates.map { context.describePath($0, in: project) })
        ]
    }
}
