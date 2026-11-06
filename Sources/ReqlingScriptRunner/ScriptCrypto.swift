import CryptoKit
import Foundation

/// Hashes, HMACs, and the byte encodings `rq.crypto`, `btoa`, and `atob` take and give, over CryptoKit.
enum ScriptCrypto {
    static func digest(_ algorithm: String, of data: Data) throws(ScriptFailure) -> Data {
        switch algorithm.lowercased() {
        case "md5": Data(Insecure.MD5.hash(data: data))
        case "sha1": Data(Insecure.SHA1.hash(data: data))
        case "sha256": Data(SHA256.hash(data: data))
        case "sha384": Data(SHA384.hash(data: data))
        case "sha512": Data(SHA512.hash(data: data))
        default: throw ScriptFailure("“\(algorithm)” isn't a hash rq.crypto knows; use md5, sha1, sha256, sha384, or sha512.")
        }
    }

    static func hmac(_ algorithm: String, key: Data, data: Data) throws(ScriptFailure) -> Data {
        let key = SymmetricKey(data: key)
        switch algorithm.lowercased() {
        case "md5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key))
        case "sha1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case "sha256": return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case "sha384": return Data(HMAC<SHA384>.authenticationCode(for: data, using: key))
        case "sha512": return Data(HMAC<SHA512>.authenticationCode(for: data, using: key))
        default: throw ScriptFailure("“\(algorithm)” isn't a hash rq.crypto.hmac knows; use md5, sha1, sha256, sha384, or sha512.")
        }
    }

    /// Bytes from text given as `utf8`, `hex`, or `base64`.
    static func bytes(_ text: String, encoding: String) throws(ScriptFailure) -> Data {
        switch encoding.lowercased() {
        case "utf8", "utf-8":
            return Data(text.utf8)
        case "hex":
            guard let data = hexData(text) else {
                throw ScriptFailure("The text isn't valid hex.")
            }
            return data
        case "base64":
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
                throw ScriptFailure("The text isn't valid base64.")
            }
            return data
        default:
            throw ScriptFailure("“\(encoding)” isn't an input encoding; use utf8, hex, or base64.")
        }
    }

    /// Text for bytes as `hex` or `base64`.
    static func text(_ data: Data, encoding: String) throws(ScriptFailure) -> String {
        switch encoding.lowercased() {
        case "hex": return data.map { String(format: "%02x", $0) }.joined()
        case "base64": return data.base64EncodedString()
        default: throw ScriptFailure("“\(encoding)” isn't an output encoding; use hex or base64.")
        }
    }

    /// `btoa`: text whose characters are each a byte (Latin-1), as base64; `nil` when one isn't.
    static func base64(latin1 text: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count)
        for unit in text.utf16 {
            guard unit <= 0xFF else {
                return nil
            }
            bytes.append(UInt8(unit))
        }
        return Data(bytes).base64EncodedString()
    }

    /// `atob`: base64, whitespace and missing padding allowed, as text with one character per byte; `nil` when it
    /// isn't base64.
    static func latin1(base64 text: String) -> String? {
        var cleaned = text.filter { !$0.isWhitespace }
        if cleaned.count % 4 != 0 {
            cleaned += String(repeating: "=", count: 4 - cleaned.count % 4)
        }
        guard let data = Data(base64Encoded: cleaned) else {
            return nil
        }
        return String(data.map { Character(Unicode.Scalar($0)) })
    }

    /// From the system's secure generator, for `crypto.getRandomValues`.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(0, count)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    private static func hexData(_ text: String) -> Data? {
        let units = Array(text.utf8)
        guard units.count.isMultiple(of: 2) else {
            return nil
        }
        var data = Data(capacity: units.count / 2)
        var index = 0
        while index < units.count {
            guard let high = hexValue(units[index]), let low = hexValue(units[index + 1]) else {
                return nil
            }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func hexValue(_ unit: UInt8) -> UInt8? {
        switch unit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): unit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): unit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): unit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
