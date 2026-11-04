/// An HTTP method: one of the standard verbs or any custom RFC 9110 token.
public struct HTTPMethod: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public static let get = HTTPMethod(rawValue: "GET")
    public static let post = HTTPMethod(rawValue: "POST")
    public static let put = HTTPMethod(rawValue: "PUT")
    public static let patch = HTTPMethod(rawValue: "PATCH")
    public static let delete = HTTPMethod(rawValue: "DELETE")
    public static let head = HTTPMethod(rawValue: "HEAD")
    public static let options = HTTPMethod(rawValue: "OPTIONS")
    public static let trace = HTTPMethod(rawValue: "TRACE")

    public static let standard: [HTTPMethod] = [.get, .post, .put, .patch, .delete, .head, .options, .trace]

    public let rawValue: String

    /// Standard verbs are case-normalized (`get` becomes `GET`); custom methods keep their spelling,
    /// since methods are case-sensitive on the wire.
    public init(rawValue: String) {
        let uppercased = rawValue.uppercased()
        let isStandard = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE"].contains(uppercased)
        self.rawValue = isStandard ? uppercased : rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }

    public var isStandard: Bool {
        Self.standard.contains(self)
    }

    /// Whether this is a syntactically valid method token (RFC 9110 §5.6.2).
    public var isValid: Bool {
        !rawValue.isEmpty && rawValue.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || Self.tokenSymbols.contains(scalar))
        }
    }

    /// The only gate on which body types a request may send; the editor, the request builder, and MCP validation all
    /// consult it. A body the policy hides stays on disk, so switching back restores it.
    public var bodyPolicy: HTTPBodyPolicy {
        switch self {
        case .get, .head, .trace:
            // URLSession also refuses a body on GET.
            return .none
        case .delete, .options:
            return .optional
        default:
            return .expected
        }
    }

    private static let tokenSymbols: Set<Unicode.Scalar> = ["!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~"]
}

public enum HTTPBodyPolicy: Sendable {
    /// The method never sends a body.
    case none
    /// A body is allowed but unusual.
    case optional
    /// The method normally carries a body.
    case expected

    public var allowsBody: Bool {
        self != .none
    }
}
