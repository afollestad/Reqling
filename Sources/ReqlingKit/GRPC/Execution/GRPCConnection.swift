import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOCore
import NIOSSL
import Security
import Synchronization

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

    /// The identity is the one `context` names for the target's host and port. Verification runs entirely in
    /// `GRPCServerTrust` (NIOSSL's hostname check is off because the SSL policy there checks the name), so the
    /// project's CAs and the system roots both count.
    private static func tlsConfiguration(
        _ context: TLSContext,
        target: GRPCTarget,
        trustFailure: TrustFailureRecorder
    ) throws(GRPCCallError) -> HTTP2ClientTransport.Posix.TransportSecurity.TLS {
        var tls = HTTP2ClientTransport.Posix.TransportSecurity.TLS.defaults
        if let identity = context.clientIdentity(target.host, target.port) {
            tls.privateKey = .customPrivateKey(try SecKeyPrivateKey(identity: identity))
            guard let leaf = identity.certificate else {
                throw .tlsFailed("The client certificate could not be read.")
            }
            tls.certificateChain = ([leaf] + identity.intermediates).map { certificate in
                .bytes([UInt8](SecCertificateCopyData(certificate) as Data), format: .der)
            }
        }
        guard context.verifiesServer else {
            tls.serverCertificateVerification = .noVerification
            return tls
        }
        tls.serverCertificateVerification = .noHostnameVerification
        let host = target.host
        tls.customVerificationCallback = { certificates, promise in
            GRPCServerTrust.verify(certificates, host: host, anchors: context.anchors, trustFailure: trustFailure, promise: promise)
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
        if let tlsError = causes.first(where: isTLSError) {
            return .failure(.tlsFailed("The TLS handshake with \(target) failed: \(tlsReason(tlsError))."))
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

    private static func isTLSError(_ error: any Error) -> Bool {
        error is NIOSSLError || error is BoringSSLError || error is NIOSSLExtraError
    }

    /// BoringSSL's reason appears only inside its OpenSSL-format error string
    /// (`error:1000045c:SSL routines:OPENSSL_internal:TLSV1_ALERT_CERTIFICATE_REQUIRED at file:line`), so it is read
    /// from there; the common ones get a sentence that says what to fix.
    private static func tlsReason(_ error: any Error) -> String {
        let text = String(describing: error)
        guard let reason = text.firstMatch(of: /OPENSSL_internal:([A-Z0-9_]+)/).map({ String($0.1) }) else {
            return text
        }
        if reason.hasSuffix("CERTIFICATE_REQUIRED") {
            return "the server requires a client certificate"
        }
        if reason == "WRONG_VERSION_NUMBER" {
            return "the server did not answer with TLS, so it may expect plaintext"
        }
        if ["ALERT_UNKNOWN_CA", "ALERT_BAD_CERTIFICATE", "ALERT_CERTIFICATE_UNKNOWN", "ALERT_ACCESS_DENIED"].contains(where: reason.hasSuffix) {
            return "the server rejected the client certificate"
        }
        if reason.hasSuffix("ALERT_HANDSHAKE_FAILURE") {
            return "the server refused the handshake, and it may require a client certificate"
        }
        return reason.lowercased().replacingOccurrences(of: "_", with: " ")
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

/// Server-certificate verification for NIOSSL's custom callback, through `TLSTrustEvaluator`.
enum GRPCServerTrust {
    /// Hops off the event loop: trust evaluation can fetch intermediates or revocation status over the network.
    static func verify(
        _ certificates: [NIOSSLCertificate],
        host: String,
        anchors: [SecCertificate],
        trustFailure: TrustFailureRecorder,
        promise: EventLoopPromise<NIOSSLVerificationResultWithMetadata>
    ) {
        let encoded: [Data]
        do {
            encoded = try certificates.map { Data(try $0.toDERBytes()) }
        } catch {
            trustFailure.record("The certificate for \(host) could not be read.")
            promise.succeed(.failed)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            switch evaluate(encoded, host: host, anchors: anchors) {
            case .success:
                promise.succeed(.certificateVerified(VerificationMetadata(nil)))
            case .failure(let error):
                trustFailure.record(error.localizedDescription)
                promise.succeed(.failed)
            }
        }
    }

    static func evaluate(_ encoded: [Data], host: String, anchors: [SecCertificate]) -> Result<Void, TLSError> {
        let certificates = encoded.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        guard !certificates.isEmpty, certificates.count == encoded.count,
              SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
                == errSecSuccess,
              let trust else {
            return .failure(.untrustedServer(host: host, reason: "The server sent no readable certificate."))
        }
        return TLSTrustEvaluator.evaluate(trust, host: host, anchors: anchors)
    }
}

/// Carries a trust-evaluation failure from NIOSSL's callback to the classification of the error that follows, which
/// otherwise only says the handshake failed.
final class TrustFailureRecorder: Sendable {
    private let stored = Mutex<String?>(nil)

    func record(_ reason: String) {
        stored.withLock { $0 = reason }
    }

    var reason: String? {
        stored.withLock { $0 }
    }
}
