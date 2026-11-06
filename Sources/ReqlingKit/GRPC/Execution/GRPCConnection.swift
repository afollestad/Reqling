import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOCore

/// How a call ended when it did not end normally, before `GRPCExecutor` or `GRPCReflectionClient` turns it into
/// their own result.
enum GRPCCallTermination: Error {
    /// A status the client assigns to a call that had not finished, such as `DEADLINE_EXCEEDED`.
    case status(GRPCStatusRecord, trailers: [KeyValuePair])
    case failure(GRPCCallError)
}

/// The transport and TLS plumbing every call shares, executor and reflection alike.
///
/// Each call gets a client and connection of its own, so its TLS policy and target never leak into another call's
/// pooled connection. The transport is NIOSSL's (Posix) rather than Network.framework's: Network.framework's custom
/// trust roots replace the system roots, and a project's CAs must be trusted *in addition to* them.
enum GRPCConnection {
    /// Runs `body` with a connected-on-demand client, shutting it down afterwards. Errors `body` lets escape from
    /// `GRPCClient` (it never got a stream) are classified; `body`'s own results pass through.
    ///
    /// The call ends when `body` does, without waiting for the connection to close, unlike `withGRPCClient`. A
    /// connection still establishing (its TCP connect pending) only sees a close once the connect finishes or NIO's
    /// connect timeout passes, and a call must end at its deadline or cancellation, not then. The connection task
    /// shuts down gracefully on its own afterwards.
    static func run<Result: Sendable>(
        target: GRPCTarget,
        security: GRPCTransportSecurity,
        _ body: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws(GRPCCallTermination) -> Result {
        let trustFailure = TrustFailureRecorder()
        let transport = try makeTransport(target: target, security: security, trustFailure: trustFailure)
        let client = GRPCClient(transport: transport)
        // Unstructured for the same reason, and so the caller's cancellation reaches the channel only through the
        // graceful shutdown below, which fails any RPC still queued for a connection rather than stranding it.
        Task {
            try? await client.runConnections()
        }
        defer {
            client.beginGracefulShutdown()
        }
        do {
            return try await withTaskCancellationHandler {
                try await body(client)
            } onCancel: {
                client.beginGracefulShutdown()
            }
        } catch {
            throw classify(error, target: target, trustFailure: trustFailure.reason)
        }
    }

    private static func makeTransport(
        target: GRPCTarget,
        security: GRPCTransportSecurity,
        trustFailure: TrustFailureRecorder
    ) throws(GRPCCallTermination) -> HTTP2ClientTransport.Posix {
        let transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity
        switch security {
        case .plaintext:
            transportSecurity = .plaintext
        case .tls(let context):
            do {
                transportSecurity = .tls(try tlsConfiguration(context, target: target, trustFailure: trustFailure))
            } catch {
                throw .failure(error)
            }
        }
        do {
            let tls = if case .tls = security { true } else { false }
            return try HTTP2ClientTransport.Posix(target: target.resolvable(tls: tls), transportSecurity: transportSecurity)
        } catch {
            let detail = (error as? RuntimeError)?.message ?? "\(error)"
            throw .failure(.tlsFailed("TLS could not be set up for \(target): \(detail)"))
        }
    }

    /// The identity is the one `context` names for the target's host and port, and verification runs in
    /// `NIOClientTLS.verify`, so the project's CAs and the system roots both count.
    private static func tlsConfiguration(
        _ context: TLSContext,
        target: GRPCTarget,
        trustFailure: TrustFailureRecorder
    ) throws(GRPCCallError) -> HTTP2ClientTransport.Posix.TransportSecurity.TLS {
        let client: NIOClientTLS
        do {
            client = try NIOClientTLS(context, host: target.host, port: target.port, trustFailure: trustFailure)
        } catch {
            throw .tlsFailed(error.localizedDescription)
        }
        var tls = HTTP2ClientTransport.Posix.TransportSecurity.TLS.defaults
        if let privateKey = client.privateKey {
            tls.privateKey = .customPrivateKey(privateKey)
            tls.certificateChain = client.certificateChain.map { .bytes($0, format: .der) }
        }
        guard client.verifiesServer else {
            tls.serverCertificateVerification = .noVerification
            return tls
        }
        tls.serverCertificateVerification = .noHostnameVerification
        tls.customVerificationCallback = { certificates, promise in
            client.verify(certificates, promise: promise)
        }
        return tls
    }

    /// Only failures that kept the call from getting a stream reach here, plus the client-side deadline and
    /// cancellation, which can interrupt any stage.
    static func classify(_ error: any Error, target: GRPCTarget, trustFailure: String?) -> GRPCCallTermination {
        if let termination = error as? GRPCCallTermination {
            return termination
        }
        if Task.isCancelled || error is CancellationError {
            return .failure(.cancelled)
        }
        if let rpcError = error as? RPCError, rpcError.code == .deadlineExceeded {
            return .status(GRPCStatusRecord(rpcError), trailers: GRPCMetadataCoding.rows(from: rpcError.metadata))
        }
        if let trustFailure {
            return .failure(.untrustedServer(trustFailure))
        }
        let causes = causeChain(of: error)
        if let tlsError = causes.first(where: NIOClientTLS.isHandshakeError) {
            return .failure(.tlsFailed("The TLS handshake with \(target) failed: \(NIOClientTLS.handshakeReason(tlsError))."))
        }
        return .failure(.connectionFailed("Could not connect to \(target): \(describe(causes.last ?? error))"))
    }

    private static func causeChain(of error: any Error) -> [any Error] {
        var chain: [any Error] = []
        var next: (any Error)? = error
        while let current = next, chain.count < 16 {
            chain.append(current)
            next = (current as? RPCError)?.cause ?? (current as? RuntimeError)?.cause
        }
        return chain
    }

    /// A socket error reads as its `strerror` text ("Connection refused") rather than NIO's call-site detail.
    private static func describe(_ error: any Error) -> String {
        if let ioError = error as? IOError {
            return String(cString: strerror(ioError.errnoCode))
        }
        if let rpcError = error as? RPCError {
            return rpcError.message
        }
        if let runtimeError = error as? RuntimeError {
            return runtimeError.message
        }
        return String(describing: error)
    }
}
