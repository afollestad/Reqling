import Foundation
import Security

/// A client identity (certificate plus private key) and the intermediates to present with it.
/// `@unchecked` because `SecIdentity` is not annotated `Sendable`, though Security's identities are immutable and
/// thread-safe once created.
public struct TLSClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let intermediates: [SecCertificate]

    public init(identity: SecIdentity, intermediates: [SecCertificate] = []) {
        self.identity = identity
        self.intermediates = intermediates
    }

    public var certificate: SecCertificate? {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        return certificate
    }
}

public enum TLSError: Error, Equatable, LocalizedError {
    case wrongPassphrase
    case unreadableIdentity(String)
    case unreadableCertificate(String)
    case missingFile(String)
    case untrustedServer(host: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase:
            "The certificate's passphrase is incorrect."
        case .unreadableIdentity(let detail):
            "The client certificate could not be read: \(detail)"
        case .unreadableCertificate(let detail):
            "The certificate could not be read: \(detail)"
        case .missingFile(let description):
            "\(description) could not be found on this Mac."
        case .untrustedServer(let host, let reason):
            "The certificate for \(host) is not trusted: \(reason)"
        }
    }
}

/// Opens PKCS#12 (`.p12`/`.pfx`) files without adding anything to a keychain.
public enum PKCS12Importer {
    public static func importIdentity(_ data: Data, passphrase: String) throws(TLSError) -> TLSClientIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw .wrongPassphrase
        default:
            throw .unreadableIdentity(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
        }
        guard let first = (items as? [[String: Any]])?.first,
              let identityValue = first[kSecImportItemIdentity as String] as CFTypeRef?,
              CFGetTypeID(identityValue) == SecIdentityGetTypeID() else {
            throw .unreadableIdentity("The file contains no identity.")
        }
        let identity = unsafeDowncast(identityValue, to: SecIdentity.self)
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        return TLSClientIdentity(identity: identity, intermediates: Array(chain.dropFirst()))
    }
}

/// Reads one or more certificates from PEM (possibly several blocks) or DER data.
public enum CertificateLoader {
    public static func certificates(from data: Data) throws(TLSError) -> [SecCertificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block -> Data? in
                guard let end = block.range(of: "-----END CERTIFICATE-----") else {
                    return nil
                }
                let base64 = block[..<end.lowerBound].filter { !$0.isWhitespace }
                return Data(base64Encoded: String(base64))
            }
            let certificates = blocks.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard !certificates.isEmpty, certificates.count == blocks.count else {
                throw .unreadableCertificate("The PEM data is malformed.")
            }
            return certificates
        }
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw .unreadableCertificate("The data is neither PEM nor DER.")
        }
        return [certificate]
    }
}

/// What the Certificates settings show about a certificate.
public struct CertificateSummary: Hashable, Sendable {
    public let subject: String
    public let issuer: String?
    public let notValidAfter: Date?

    public init(subject: String, issuer: String?, notValidAfter: Date?) {
        self.subject = subject
        self.issuer = issuer
        self.notValidAfter = notValidAfter
    }

    public init(_ certificate: SecCertificate) {
        subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown subject"
        notValidAfter = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        issuer = Self.issuerCommonName(certificate)
    }

    public func isExpired(at date: Date) -> Bool {
        notValidAfter.map { $0 < date } ?? false
    }

    private static func issuerCommonName(_ certificate: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1IssuerName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
              let issuer = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
              let entries = issuer[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return nil
        }
        let commonName = entries.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDCommonName as String) }
        return commonName?[kSecPropertyKeyValue as String] as? String
    }
}
