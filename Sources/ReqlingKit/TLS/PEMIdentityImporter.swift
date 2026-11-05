import CryptoKit
import Foundation
import NIOSSL
import Security

/// Builds a client identity from a PEM certificate and private key without adding anything to a keychain.
///
/// Security has no public API that makes a `SecIdentity` from a loose certificate and key, so NIOSSL (BoringSSL)
/// reads the key — RSA or EC; PKCS#1, SEC1, or PKCS#8; plain, encrypted PKCS#8, or legacy `Proc-Type` encrypted — and
/// repackages the pair as an in-memory PKCS#12 that `PKCS12Importer` opens. It skips `PKCS12ImportProbe`: matching the key
/// to its leaf already proves Security can read the leaf's key, whose absence is what crashes the importer.
public enum PEMIdentityImporter {
    /// `certificate` is PEM (one or more blocks; a combined file may hold the key too) or DER. The leaf is whichever
    /// certificate the key belongs to, and the rest become intermediates.
    public static func importIdentity(certificate: Data, key: Data, passphrase: String) throws(TLSError) -> TLSClientIdentity {
        let certificates = try CertificateLoader.certificates(from: certificate)
        let privateKey = try readPrivateKey(key, passphrase: passphrase)
        let publicKey = try publicKeyRepresentation(of: privateKey)
        // Matching first also guards `serialize(passphrase:)`, which dereferences NULL when BoringSSL refuses a key
        // that doesn't belong to the certificate, and traps on an empty chain.
        guard let leafIndex = certificates.firstIndex(where: { externalRepresentation(of: $0) == publicKey }) else {
            // Security reads no key from a certificate with explicit EC curve parameters, so it can never match.
            if certificates.contains(where: { SecCertificateCopyKey($0) == nil }) {
                throw .unsupportedCertificate
            }
            throw .unreadableIdentity("The private key does not match the certificate.")
        }
        var chain = certificates
        chain.insert(chain.remove(at: leafIndex), at: 0)
        let transientPassphrase = UUID().uuidString
        let pkcs12: [UInt8]
        do {
            let bundle = NIOSSLPKCS12Bundle(
                certificateChain: try chain.map { try NIOSSLCertificate(bytes: [UInt8](SecCertificateCopyData($0) as Data), format: .der) },
                privateKey: privateKey
            )
            pkcs12 = try bundle.serialize(passphrase: Array(transientPassphrase.utf8))
        } catch {
            throw .unreadableIdentity("The certificate and key could not be combined.")
        }
        return try PKCS12Importer.importChecked(Data(pkcs12), passphrase: transientPassphrase)
    }

    /// Whether PEM `data` holds a private key, so a certificate chosen alone needs no separate key file.
    public static func containsPrivateKey(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.range(of: "-----BEGIN [A-Z ]*PRIVATE KEY-----", options: .regularExpression) != nil
    }

    /// BoringSSL asks for the passphrase only when the key is encrypted, so a failure after it asked means the
    /// passphrase was wrong (or missing), not that the file is unreadable.
    private static func readPrivateKey(_ data: Data, passphrase: String) throws(TLSError) -> NIOSSLPrivateKey {
        // NIOSSL force-unwraps the buffer's base address, which an empty buffer lacks.
        guard !data.isEmpty else {
            throw .unreadableIdentity("The private key could not be read.")
        }
        var askedForPassphrase = false
        do {
            return try NIOSSLPrivateKey(bytes: [UInt8](data), format: .pem) { (setPassphrase: NIOSSLPassphraseSetter<[UInt8]>) in
                askedForPassphrase = true
                setPassphrase(Array(passphrase.utf8))
            }
        } catch {
            throw askedForPassphrase ? .wrongPassphrase : .unreadableIdentity("The private key could not be read.")
        }
    }

    /// The key's public half as Security represents a certificate's key: PKCS#1 for RSA, X9.63 for EC.
    private static func publicKeyRepresentation(of key: NIOSSLPrivateKey) throws(TLSError) -> Data {
        // RSA keys come out as PKCS#1 and EC keys as SEC1, whatever form the file used.
        guard let der = try? Data(key.derBytes) else {
            throw .unreadableIdentity("Use an RSA or EC key.")
        }
        // EC first: CryptoKit refuses another key type quietly, where Security logs each refusal.
        if let ecKey = try? P256.Signing.PrivateKey(derRepresentation: der) {
            return ecKey.publicKey.x963Representation
        }
        if let ecKey = try? P384.Signing.PrivateKey(derRepresentation: der) {
            return ecKey.publicKey.x963Representation
        }
        if let ecKey = try? P521.Signing.PrivateKey(derRepresentation: der) {
            return ecKey.publicKey.x963Representation
        }
        let rsaAttributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        if let rsa = SecKeyCreateWithData(der as CFData, rsaAttributes, nil),
           let publicKey = SecKeyCopyPublicKey(rsa),
           let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
            return representation
        }
        throw .unreadableIdentity("Use an RSA or EC key.")
    }

    private static func externalRepresentation(of certificate: SecCertificate) -> Data? {
        SecCertificateCopyKey(certificate).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
    }
}
