import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Where a gRPC call connects. Parsed from `host:port`, `[ipv6]:port`, or `unix:/path/to.sock`
/// (`unix:///path` also works, as gRPC's own naming allows).
public struct GRPCTarget: Hashable, Sendable, CustomStringConvertible {
    public enum Endpoint: Hashable, Sendable {
        /// A DNS name or an IP literal; IPv6 literals are stored without brackets.
        case host(String, port: Int)
        case unixSocket(path: String)
    }

    public let endpoint: Endpoint

    public init(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    /// Parses a target as the editor shows it. A port is required: gRPC has no default one, and guessing 443 or 80
    /// would silently reach the wrong service.
    public init(parsing text: String) throws(GRPCCallError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("unix:") {
            var path = String(trimmed.dropFirst("unix:".count))
            if path.hasPrefix("//") {
                path = String(path.dropFirst(2))
            }
            guard !path.isEmpty else {
                throw .invalidRequest("The Unix socket target has no path; use unix:/path/to.sock.")
            }
            self.init(.unixSocket(path: path))
            return
        }
        guard !trimmed.isEmpty else {
            throw .invalidRequest("The target is empty; use host:port.")
        }
        guard !trimmed.contains("/"), !trimmed.contains(where: \.isWhitespace) else {
            throw .invalidRequest("“\(trimmed)” is not a gRPC target; use host:port without a scheme or path.")
        }
        let (host, portText) = try Self.split(trimmed)
        guard !host.isEmpty else {
            throw .invalidRequest("“\(trimmed)” has no host.")
        }
        guard let port = Int(portText), (1...65_535).contains(port) else {
            throw .invalidRequest("“\(portText)” is not a port number between 1 and 65535.")
        }
        self.init(.host(String(host), port: port))
    }

    /// Splits `host:port` or `[ipv6]:port` at the port's colon.
    private static func split(_ text: String) throws(GRPCCallError) -> (host: Substring, port: Substring) {
        guard text.hasPrefix("[") else {
            guard let colon = text.lastIndex(of: ":") else {
                throw .invalidRequest("“\(text)” has no port; use \(text):port.")
            }
            let host = text[..<colon]
            guard !host.contains(":") else {
                throw .invalidRequest("Wrap an IPv6 address in brackets, such as [::1]:50051.")
            }
            return (host, text[text.index(after: colon)...])
        }
        guard let close = text.firstIndex(of: "]") else {
            throw .invalidRequest("“\(text)” has an unclosed IPv6 bracket.")
        }
        let host = text[text.index(after: text.startIndex)..<close]
        let rest = text[text.index(after: close)...]
        guard rest.hasPrefix(":") else {
            throw .invalidRequest("“\(text)” has no port; use [\(host)]:port.")
        }
        return (host, rest.dropFirst())
    }

    /// The name the server certificate is verified against and the client identity is looked up by. A Unix socket
    /// has no host name, so it uses `localhost`, which is what a certificate for a local daemon names.
    public var host: String {
        switch endpoint {
        case .host(let host, _): host
        case .unixSocket: "localhost"
        }
    }

    public var port: Int? {
        switch endpoint {
        case .host(_, let port): port
        case .unixSocket: nil
        }
    }

    public var description: String {
        switch endpoint {
        case .host(let host, let port) where host.contains(":"): "[\(host)]:\(port)"
        case .host(let host, let port): "\(host):\(port)"
        case .unixSocket(let path): "unix:\(path)"
        }
    }

    /// IP literals get their own resolvers: DNS resolution of a literal works, but the explicit forms skip a lookup
    /// and keep SNI off (literals are not allowed in SNI). A Unix socket over TLS names `localhost` as its authority,
    /// so SNI and `:authority` match the name `host` verifies the certificate against, rather than the socket path.
    func resolvable(tls: Bool) -> any ResolvableTarget {
        switch endpoint {
        case .host(let host, let port) where host.contains(":"):
            .ipv6(address: host, port: port)
        case .host(let host, let port) where Self.isIPv4Literal(host):
            .ipv4(address: host, port: port)
        case .host(let host, let port):
            .dns(host: host, port: port)
        case .unixSocket(let path):
            .unixDomainSocket(path: path, authority: tls ? host : nil)
        }
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }
}
