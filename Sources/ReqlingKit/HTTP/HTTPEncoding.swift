import Foundation
import UniformTypeIdentifiers

/// Percent-encoding for the places a request puts user text.
enum HTTPEncoding {
    /// Encodes a query name or value. Valid escapes the user already typed (`%20`) are kept, so encoding happens
    /// exactly once whether or not the text was pre-encoded; `&`, `=`, `+`, and `#` are always escaped.
    static func queryComponent(_ text: String) -> String {
        var result = ""
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                for escapeByte in bytes[index...(index + 2)] {
                    result.unicodeScalars.append(Unicode.Scalar(escapeByte))
                }
                index += 3
                continue
            }
            if queryAllowed.contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
            index += 1
        }
        return result
    }

    /// `name=value` items joined with `&`; an empty value sends the bare name (`?flag`).
    static func query(_ items: [(String, String)]) -> String {
        items.map { key, value in
            value.isEmpty ? queryComponent(key) : "\(queryComponent(key))=\(queryComponent(value))"
        }
        .joined(separator: "&")
    }

    /// `application/x-www-form-urlencoded` encoding: space becomes `+`, everything but `*-._` and alphanumerics is
    /// escaped. Form values are data rather than URL text, so a typed `%` is escaped too.
    static func formComponent(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if byte == UInt8(ascii: " ") {
                result += "+"
            } else if isAlphanumeric(byte) || [UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_")].contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// Escapes characters `URLComponents` rejects (spaces, braces, non-ASCII) while leaving URL syntax alone.
    static func lenientURL(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if byte == UInt8(ascii: "%") || urlAllowed.contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// The MIME type for a file name's extension, or `application/octet-stream`.
    static func mimeType(forFileName name: String) -> String {
        let fileExtension = (name as NSString).pathExtension
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static let unreserved: Set<UInt8> = Set(Array("-._~".utf8))
    private static let queryAllowed: Set<UInt8> = unreserved
        .union(Array("!$'()*,;:@/?".utf8))
        .union((UInt8(ascii: "a")...UInt8(ascii: "z")))
        .union((UInt8(ascii: "A")...UInt8(ascii: "Z")))
        .union((UInt8(ascii: "0")...UInt8(ascii: "9")))
    private static let urlAllowed: Set<UInt8> = queryAllowed.union(Array("&=+#[]".utf8))

    private static func isHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// A header Reqling adds on its own. Overridable ones can be turned off or replaced by a user header of the same
/// name; the others are set by the URL loading system and shown for information only.
public struct AutoHeader: Hashable, Sendable {
    public let name: String
    public let value: String
    public let isOverridable: Bool
    /// What macOS sends in this header's place once it is turned off, such as "*/*"; `nil` when nothing is sent.
    public let systemFallback: String?
    /// Whether it is sent until turned off; one that is off by default (a WebSocket's `Origin`) is sent once turned on.
    public let isOnByDefault: Bool

    public init(name: String, value: String, isOverridable: Bool, systemFallback: String? = nil, isOnByDefault: Bool = true) {
        self.name = name
        self.value = value
        self.isOverridable = isOverridable
        self.systemFallback = systemFallback
        self.isOnByDefault = isOnByDefault
    }

    public var key: String {
        name.lowercased()
    }
}

/// Encodes `multipart/form-data` bodies.
struct MultipartEncoder {
    struct Part {
        var name: String
        var fileName: String?
        var contentType: String?
        var data: Data
    }

    let boundary: String

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    func encode(_ parts: [Part]) -> Data {
        var body = Data()
        for part in parts {
            body.append("--\(boundary)\r\n")
            var disposition = "Content-Disposition: form-data; name=\"\(Self.quoted(part.name))\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(Self.quoted(fileName))\""
            }
            body.append("\(disposition)\r\n")
            if let contentType = part.contentType {
                body.append("Content-Type: \(contentType)\r\n")
            }
            body.append("\r\n")
            body.append(part.data)
            body.append("\r\n")
        }
        body.append("--\(boundary)--\r\n")
        return body
    }

    /// Escapes the characters a quoted `Content-Disposition` parameter cannot hold, as browsers do.
    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }
}

extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
