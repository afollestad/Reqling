import Foundation
import NIOCore
import NIOSSL
import Security
import Synchronization

/// A `TLSContext` resolved for one client connection made with SwiftNIO: the client identity the context names for
/// the connection's host and port, and server verification through `TLSTrustEvaluator`.
///
/// Verification runs entirely in `verify`, NIOSSL's custom callback, with NIOSSL's own hostname check off and its trust
/// roots unset: the SSL policy there checks the name, and NIOSSL's roots would replace the system's where the project's
/// CAs must be trusted *in addition to* them.
struct NIOClientTLS: Sendable {
    let verifiesServer: Bool
    /// Signs with the identity's `SecKey`; `nil` when the context has no identity for the host and port.
    let privateKey: SecKeyPrivateKey?
    /// The identity's certificate, then its intermediates, DER-encoded; empty without an identity.
    let certificateChain: [[UInt8]]
    private let host: String
    private let anchors: [SecCertificate]
    private let trustFailure: TrustFailureRecorder

    /// `trustFailure` receives why `verify` refused the server, for the error the failed handshake raises next.
    init(_ context: TLSContext, host: String, port: Int?, trustFailure: TrustFailureRecorder) throws(TLSError) {
        verifiesServer = context.verifiesServer
        self.host = host
        anchors = context.anchors
        self.trustFailure = trustFailure
        guard let identity = context.clientIdentity(host, port) else {
            privateKey = nil
            certificateChain = []
            return
        }
        privateKey = try SecKeyPrivateKey(identity: identity)
        guard let leaf = identity.certificate else {
            throw .unusableClientIdentity("The client certificate could not be read.")
        }
        certificateChain = ([leaf] + identity.intermediates).map { [UInt8](SecCertificateCopyData($0) as Data) }
    }

    /// NIOSSL's custom verification callback. Hops off the event loop: trust evaluation can fetch intermediates or
    /// revocation status over the network.
    func verify(_ certificates: [NIOSSLCertificate], promise: EventLoopPromise<NIOSSLVerificationResultWithMetadata>) {
        let encoded: [Data]
        do {
            encoded = try certificates.map { Data(try $0.toDERBytes()) }
        } catch {
            trustFailure.record("The certificate for \(host) could not be read.")
            promise.succeed(.failed)
            return
        }
        let (host, anchors, trustFailure) = (host, anchors, trustFailure)
        DispatchQueue.global(qos: .userInitiated).async {
            switch Self.evaluate(encoded, host: host, anchors: anchors) {
            case .success:
                promise.succeed(.certificateVerified(VerificationMetadata(nil)))
            case .failure(let error):
                trustFailure.record(error.localizedDescription)
                promise.succeed(.failed)
            }
        }
    }

    private static func evaluate(_ encoded: [Data], host: String, anchors: [SecCertificate]) -> Result<Void, TLSError> {
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

    /// Whether `error` came from the TLS layer rather than the socket or the protocol above it.
    static func isHandshakeError(_ error: any Error) -> Bool {
        error is NIOSSLError || error is BoringSSLError || error is NIOSSLExtraError
    }

    /// Why a handshake failed. BoringSSL's reason appears only inside its OpenSSL-format error string
    /// (`error:1000045c:SSL routines:OPENSSL_internal:TLSV1_ALERT_CERTIFICATE_REQUIRED at file:line`), so it is read
    /// from there; the common ones get a sentence that says what to fix.
    static func handshakeReason(_ error: any Error) -> String {
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
