import Foundation

/// Certificates for a run: the project's CAs and the client certificate for its host, shared by HTTP, gRPC, and
/// WebSocket runs so one host always gets the same ones.
extension RequestRunner {
    /// The certificates a prepared request uses: the project's CAs and the client certificate for its host.
    func tls(for prepared: PreparedHTTPRequest, project: ProjectID, context: RunContext) throws(RunFailure) -> TLSContext {
        try tls(for: prepared, project: project, context: context, reusing: nil).context
    }

    /// `tls(for:project:context:)`, reusing `earlier` when it was built for the same host, port, and verification: a
    /// schema lookup prepares its request twice, script-free for its cache key and then as scripts left it, and a script
    /// can set a variable its URL uses, so only an unchanged endpoint shares the certificates read for the first.
    func tls(
        for prepared: PreparedHTTPRequest,
        project: ProjectID,
        context: RunContext,
        reusing earlier: PreparedTLS?
    ) throws(RunFailure) -> PreparedTLS {
        let url = prepared.urlRequest.url
        let host = url?.host ?? ""
        let port = url?.port ?? (["https", "wss"].contains(url?.scheme?.lowercased()) ? 443 : 80)
        if let earlier, earlier.host == host, earlier.port == port, earlier.verifiesServer == prepared.verifyTLS {
            return earlier
        }
        do {
            let built = try tlsContext(host: host, port: port, verifiesServer: prepared.verifyTLS, project: project, context: context)
            return PreparedTLS(host: host, port: port, verifiesServer: prepared.verifyTLS, context: built)
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    /// Snapshots what TLS needs off the main actor (passphrases and Keychain references), then loads the identity and
    /// CAs for `host` and `port`. HTTP and gRPC both build their context here, so one host gets the same certificates.
    func tlsContext(host: String, port: Int?, verifiesServer: Bool, project: ProjectID, context: RunContext) throws(RunFailure) -> TLSContext {
        try tlsContext(host: host, port: port, verifiesServer: verifiesServer, project: project, from: (context.document, context.paths))
    }

    /// The certificates a request sent outside a run uses, such as one a script sends, for its URL's host and port.
    func tlsContext(
        for prepared: PreparedHTTPRequest,
        project: ProjectID,
        document: ProjectDocument,
        paths: ProjectPathResolver
    ) throws(RunFailure) -> TLSContext {
        let url = prepared.urlRequest.url
        let port = url?.port ?? (url?.scheme?.lowercased() == "https" ? 443 : 80)
        do {
            return try tlsContext(host: url?.host ?? "", port: port, verifiesServer: prepared.verifyTLS, project: project, from: (document, paths))
        } catch {
            throw error.redacting(prepared.redaction)
        }
    }

    /// `from` is where the project's TLS settings are read: its document, and its files' paths.
    private func tlsContext(
        host: String,
        port: Int?,
        verifiesServer: Bool,
        project: ProjectID,
        from source: (document: ProjectDocument, paths: ProjectPathResolver)
    ) throws(RunFailure) -> TLSContext {
        let configuration = source.document.tls
        let entries = configuration.clientCertificates
        let passphrases = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            library.certificatePassphrase(for: entry.id, in: project).map { (entry.id, $0) }
        })
        let references = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            workspace.keychainIdentity(for: entry.id).map { (entry.id, $0) }
        })
        let resolver = ProjectTLSResolver(
            configuration: configuration,
            paths: source.paths,
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
    /// The run started from values an earlier step of its folder or project run made secret for that run alone.
    var heldRunLocalSecrets = false

    func applied(to exchange: RequestExchange) -> RequestExchange {
        var stamped = exchange
        stamped.id = id
        stamped.spec = spec
        if heldRunLocalSecrets {
            stamped.heldRunLocalSecrets = true
        }
        if let environment {
            stamped.environmentID = environment.id
            stamped.environmentName = environment.name
        }
        return stamped
    }
}

/// A TLS context with the endpoint it was built for, so one lookup that prepares an endpoint twice reads the project's
/// certificates once (`RequestRunner.tls(for:project:context:reusing:)`).
struct PreparedTLS {
    let host: String
    let port: Int
    let verifiesServer: Bool
    let context: TLSContext
}
