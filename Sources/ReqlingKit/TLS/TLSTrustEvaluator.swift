import CryptoKit
import Foundation
import Security

/// Decides whether to trust a server, using the system roots plus a project's extra CA certificates. The extra CAs
/// never replace the system roots: a project that trusts its internal CA must still reach public hosts.
public enum TLSTrustEvaluator {
    /// Evaluates `trust` for `host` with the SSL policy. `anchors` are trusted *in addition to* the system roots.
    public static func evaluate(_ trust: SecTrust, host: String, anchors: [SecCertificate]) -> Result<Void, TLSError> {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return .success(())
        }
        let reason = error.map { CFErrorCopyDescription($0) as String } ?? "Evaluation failed."
        return .failure(.untrustedServer(host: host, reason: reason))
    }
}

/// The TLS behavior one request runs with: whether and how to verify the server, and which client identity to present.
public struct TLSContext: Sendable {
    public let verifiesServer: Bool
    public let anchors: [SecCertificate]
    /// The identity for a host and port; consulted when a server asks for a client certificate, including after
    /// a redirect to another host.
    public let clientIdentity: @Sendable (_ host: String, _ port: Int?) -> TLSClientIdentity?
    /// Identifies the anchors and the client identities, so `HTTPExecutor` never reuses a connection set up under
    /// different TLS settings. A digest, so it can be kept without holding passphrases or keys.
    public let fingerprint: Data

    /// `identitySource` describes everything `clientIdentity` answers from (for a project, its certificate entries
    /// with their files and passphrases); the anchors are added to the fingerprint here.
    public init(
        verifiesServer: Bool = true,
        anchors: [SecCertificate] = [],
        identitySource: Data = Data(),
        clientIdentity: @escaping @Sendable (_ host: String, _ port: Int?) -> TLSClientIdentity? = { _, _ in nil }
    ) {
        self.verifiesServer = verifiesServer
        self.anchors = anchors
        self.clientIdentity = clientIdentity
        var hash = SHA256()
        for anchor in anchors {
            hash.update(data: SecCertificateCopyData(anchor) as Data)
        }
        hash.update(data: identitySource)
        fingerprint = Data(hash.finalize())
    }

    public static let `default` = TLSContext()
}
