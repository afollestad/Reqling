import Foundation

/// Certificates for a run: the project's CAs and the client certificate for its host, shared by HTTP, gRPC, and
/// WebSocket runs so one host always gets the same ones.
extension RequestRunner {
    /// The certificates a prepared request uses: the project's CAs and the client certificate for its host.
    func tls(for prepared: PreparedHTTPRequest, project: ProjectID, context: RunContext) throws(RunFailure) -> TLSContext {
        let url = prepared.urlRequest.url
        do {
            return try tlsContext(
                host: url?.host ?? "",
                port: url?.port ?? (["https", "wss"].contains(url?.scheme?.lowercased()) ? 443 : 80),
                verifiesServer: prepared.verifyTLS,
                project: project,
                context: context
            )
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    /// Snapshots what TLS needs off the main actor (passphrases and Keychain references), then loads the identity and
    /// CAs for `host` and `port`. HTTP and gRPC both build their context here, so one host gets the same certificates.
    func tlsContext(host: String, port: Int?, verifiesServer: Bool, project: ProjectID, context: RunContext) throws(RunFailure) -> TLSContext {
        let configuration = context.document.tls
        let entries = configuration.clientCertificates
        let passphrases = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            library.certificatePassphrase(for: entry.id, in: project).map { (entry.id, $0) }
        })
        let references = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            workspace.keychainIdentity(for: entry.id).map { (entry.id, $0) }
        })
        let resolver = ProjectTLSResolver(
            configuration: configuration,
            paths: context.paths,
            passphrase: { passphrases[$0] },
            keychainIdentityReference: { references[$0] },
            keychain: keychain,
            pkcs12Probe: pkcs12Probe
        )
        do {
            return try resolver.context(host: host, port: port, verifiesServer: verifiesServer)
        } catch {
            throw RunFailure(kind: .tls, message: error.localizedDescription)
        }
    }
}

/// What every exchange of one run carries, whichever path produced it: a failure before sending, a response, or a
/// live run's partial and final records.
struct RunStamp {
    let id: RunID
    let startedAt: Date
    let spec: RequestKind?
    /// `nil` when the project is gone or the environment named for the run no longer exists.
    let environment: RequestEnvironment?

    func applied(to exchange: RequestExchange) -> RequestExchange {
        var stamped = exchange
        stamped.id = id
        stamped.spec = spec
        if let environment {
            stamped.environmentID = environment.id
            stamped.environmentName = environment.name
        }
        return stamped
    }
}
