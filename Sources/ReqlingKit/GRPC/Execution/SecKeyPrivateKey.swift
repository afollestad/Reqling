import Foundation
import NIOCore
import NIOSSL
import Security

/// Signs TLS handshakes with a client identity's `SecKey`, so the key never leaves Security: an in-memory PKCS#12 key
/// and a Keychain key (which usually cannot be exported at all) work the same way.
///
/// `@unchecked` because `SecKey` is not annotated `Sendable`, though Security's keys are immutable and thread-safe
/// once created; `algorithms` is an immutable value.
struct SecKeyPrivateKey: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    let key: SecKey
    /// In preference order, and only those the key reports it can perform.
    let signatureAlgorithms: [SignatureAlgorithm]
    private let algorithms: [SignatureAlgorithm: SecKeyAlgorithm]

    init(identity: TLSClientIdentity) throws(GRPCCallError) {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity.identity, &key) == errSecSuccess, let key else {
            throw .tlsFailed("The client certificate's private key could not be read.")
        }
        try self.init(key: key)
    }

    init(key: SecKey) throws(GRPCCallError) {
        let candidates = Self.candidates(for: key).filter { SecKeyIsAlgorithmSupported(key, .sign, $0.1) }
        guard !candidates.isEmpty else {
            throw .tlsFailed("The client certificate's key type cannot sign TLS handshakes; use an EC or RSA key.")
        }
        self.key = key
        signatureAlgorithms = candidates.map(\.0)
        algorithms = Dictionary(candidates) { first, _ in first }
    }

    /// Hops off the event loop: signing with a Keychain key can wait on an access prompt or a smart card, and the
    /// event loop is shared by every connection.
    func sign(channel: any Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let input = Data(data.readableBytesView)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                promise.succeed(ByteBuffer(bytes: try signature(for: algorithm, data: input)))
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    /// Only RSA key exchange decrypts, and only a server ever does; a client key never gets here.
    func decrypt(channel: any Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(SigningError(message: "Client keys never decrypt."))
    }

    /// `data` is unhashed, as NIOSSL hands it over; the `…Message…` algorithms hash it. ECDSA signatures come back
    /// DER-encoded, which is the form TLS carries.
    func signature(for algorithm: SignatureAlgorithm, data: Data) throws -> Data {
        guard let secAlgorithm = algorithms[algorithm] else {
            throw SigningError(message: "The client key cannot sign with TLS algorithm 0x\(String(algorithm.rawValue, radix: 16)).")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, secAlgorithm, data as CFData, &error) as Data? else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "Signing failed."
            throw SigningError(message: reason)
        }
        return signature
    }

    static func == (lhs: SecKeyPrivateKey, rhs: SecKeyPrivateKey) -> Bool {
        CFEqual(lhs.key, rhs.key)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(key))
    }

    /// TLS 1.3 binds each ECDSA algorithm to one curve, so an EC key offers only its own; RSA offers PSS first,
    /// which TLS 1.3 requires, then PKCS#1 for older servers.
    private static func candidates(for key: SecKey) -> [(SignatureAlgorithm, SecKeyAlgorithm)] {
        let attributes = SecKeyCopyAttributes(key) as? [String: Any] ?? [:]
        let type = attributes[kSecAttrKeyType as String] as? String
        let bits = (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue ?? 0
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch bits {
            case 384: return [(.ecdsaSecp384R1Sha384, .ecdsaSignatureMessageX962SHA384)]
            case 521: return [(.ecdsaSecp521R1Sha512, .ecdsaSignatureMessageX962SHA512)]
            default: return [(.ecdsaSecp256R1Sha256, .ecdsaSignatureMessageX962SHA256)]
            }
        }
        if type == (kSecAttrKeyTypeRSA as String) {
            return [
                (.rsaPssRsaeSha256, .rsaSignatureMessagePSSSHA256),
                (.rsaPssRsaeSha384, .rsaSignatureMessagePSSSHA384),
                (.rsaPssRsaeSha512, .rsaSignatureMessagePSSSHA512),
                (.rsaPkcs1Sha256, .rsaSignatureMessagePKCS1v15SHA256),
                (.rsaPkcs1Sha384, .rsaSignatureMessagePKCS1v15SHA384),
                (.rsaPkcs1Sha512, .rsaSignatureMessagePKCS1v15SHA512),
                (.rsaPkcs1Sha1, .rsaSignatureMessagePKCS1v15SHA1)
            ]
        }
        return []
    }
}

private struct SigningError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}
