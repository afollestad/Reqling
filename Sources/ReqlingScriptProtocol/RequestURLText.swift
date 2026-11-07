import Foundation

/// How typed text becomes a request's URL: trimmed, `http://` when it names no scheme, and escaped where
/// `URLComponents` would refuse it. `HTTPRequestBuilder` builds every request's URL through it and `ScriptCookieScope`
/// parses a script's cookie target through it, so `rq.cookies` names the URL a request is sent to; never copy it.
public enum RequestURLText {
    /// The URL's parts, or `nil` when the text is empty or names no host.
    public static func components(_ text: String) -> URLComponents? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if !text.contains("://") {
            text = "http://\(text)"
        }
        guard let components = URLComponents(string: text) ?? URLComponents(string: lenient(text)),
              components.host?.isEmpty == false else {
            return nil
        }
        return components
    }

    /// Escapes characters `URLComponents` rejects (spaces, braces, non-ASCII) while leaving URL syntax alone.
    static func lenient(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if byte == UInt8(ascii: "%") || allowed.contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static let allowed: Set<UInt8> = Set(Array("-._~!$'()*,;:@/?&=+#[]".utf8))
        .union((UInt8(ascii: "a")...UInt8(ascii: "z")))
        .union((UInt8(ascii: "A")...UInt8(ascii: "Z")))
        .union((UInt8(ascii: "0")...UInt8(ascii: "9")))
}
