import Foundation
import GRPCCore

/// Converts between the editor's metadata rows and GRPCCore's `Metadata`. Binary (`-bin`) values travel as base64 in
/// rows both ways, so a row can always be shown and edited as text.
enum GRPCMetadataCoding {
    /// Headers the transport writes itself; a second copy from the user would make the request malformed.
    private static let transportKeys: Set<String> = ["content-type"]
    /// HTTP/1 connection headers, which HTTP/2 forbids (RFC 9113 §8.2.2); a server would reset the stream with an
    /// opaque protocol error, so they are refused here with one that says why. `te: trailers` is the one allowed
    /// form, and the transport already sends it.
    private static let connectionKeys: Set<String> = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"]

    static func metadata(from rows: [KeyValuePair]) throws(GRPCCallError) -> Metadata {
        var metadata = Metadata()
        for row in rows where row.isEnabled {
            let key = row.key.trimmingCharacters(in: .whitespaces).lowercased()
            if key.isEmpty {
                continue
            }
            guard key.unicodeScalars.allSatisfy(isKeyCharacter) else {
                throw .invalidRequest("Metadata key “\(row.key)” may only use letters, digits, “-”, “_”, and “.”.")
            }
            guard !transportKeys.contains(key), !key.hasPrefix("grpc-") else {
                throw .invalidRequest("Metadata key “\(key)” is reserved for gRPC itself.")
            }
            if key == "te" {
                guard row.value.trimmingCharacters(in: .whitespaces).lowercased() == "trailers" else {
                    throw .invalidRequest("HTTP/2 allows “te” only as “trailers”, which gRPC already sends.")
                }
                continue
            }
            guard !connectionKeys.contains(key) else {
                throw .invalidRequest("“\(key)” is an HTTP/1 connection header, which HTTP/2 forbids; remove it from the metadata.")
            }
            if key.hasSuffix("-bin") {
                guard let bytes = decodeBase64(row.value) else {
                    throw .invalidRequest("Metadata “\(key)” must be base64, since its key ends in -bin.")
                }
                metadata.addBinary(bytes, forKey: key)
            } else {
                guard row.value.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
                    throw .invalidRequest(
                        "Metadata “\(key)” must be printable ASCII; send other bytes base64-encoded under a key ending in -bin."
                    )
                }
                metadata.addString(row.value, forKey: key)
            }
        }
        return metadata
    }

    /// Received metadata as rows. HTTP/2 pseudo-headers (`:status`) are framing rather than gRPC metadata.
    static func rows(from metadata: Metadata) -> [KeyValuePair] {
        metadata.compactMap { key, value in
            if key.hasPrefix(":") {
                return nil
            }
            switch value {
            case .string(let text):
                return KeyValuePair(key: key, value: text)
            case .binary(let bytes):
                return KeyValuePair(key: key, value: Data(bytes).base64EncodedString())
            }
        }
    }

    private static func isKeyCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."z", "-", "_", ".": true
        default: false
        }
    }

    /// gRPC peers may omit base64 padding, so it is restored before decoding.
    private static func decodeBase64(_ text: String) -> [UInt8]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let padded = trimmed + String(repeating: "=", count: (4 - trimmed.count % 4) % 4)
        return Data(base64Encoded: padded).map { [UInt8]($0) }
    }
}

extension GRPCStatusRecord {
    /// A status with its canonical name (`DEADLINE_EXCEEDED`) filled in from `code`.
    init(code: Int, message: String) {
        self.init(code: code, name: Self.canonicalName(code), message: message)
    }

    init(_ error: RPCError) {
        self.init(code: error.code.rawValue, message: error.message)
    }

    /// GRPCCore's own descriptions are camel-case (`deadlineExceeded`); people and other tools know these names.
    static func canonicalName(_ code: Int) -> String {
        let names = [
            "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED", "NOT_FOUND", "ALREADY_EXISTS",
            "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
            "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS", "UNAUTHENTICATED"
        ]
        return names.indices.contains(code) ? names[code] : "CODE_\(code)"
    }

    static let okay = GRPCStatusRecord(code: 0, message: "")
}
