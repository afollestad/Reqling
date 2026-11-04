import Foundation
import MCP

/// Parses one HTTP/1.1 request from a connection's bytes, strictly: a bounded head, an exact `Content-Length` (POST
/// must send one), no chunked bodies, no duplicate headers, and a plain path with no query or escapes. Anything else
/// is refused before it reaches the MCP transport.
enum MCPHTTPRequestParser {
    enum Result {
        case incomplete
        case failure(statusCode: Int)
        case request(path: String, request: HTTPRequest)
    }

    private struct RequestHead {
        let method: String
        let path: String
        let headers: [String: String]
    }

    static func parse(_ data: Data, maxHeaderBytes: Int, maxBodyBytes: Int) -> Result {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .failure(statusCode: 413) : .incomplete
        }
        guard headerRange.lowerBound <= maxHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .failure(statusCode: 413)
        }
        guard let head = requestHead(from: headerText),
              let contentLength = contentLength(for: head) else {
            return .failure(statusCode: 400)
        }
        guard contentLength <= maxBodyBytes else {
            return .failure(statusCode: 413)
        }
        let bodyStart = headerRange.upperBound
        guard data.count - bodyStart >= contentLength else {
            return .incomplete
        }
        guard data.count - bodyStart == contentLength else {
            return .failure(statusCode: 400)
        }
        guard head.path.hasPrefix("/"), !head.path.contains("%"), !head.path.contains("?") else {
            return .failure(statusCode: 400)
        }
        return .request(
            path: head.path,
            request: HTTPRequest(
                method: head.method,
                headers: head.headers,
                body: Data(data[bodyStart..<bodyStart + contentLength]),
                path: head.path
            )
        )
    }

    private static func requestHead(from headerText: String) -> RequestHead? {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestParts.count == 3, requestParts[2] == "HTTP/1.1" else {
            return nil
        }
        var headers: [String: String] = [:]
        var headerNames = Set<String>()
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headerNames.insert(name.lowercased()).inserted else {
                return nil
            }
            headers[name] = value
        }
        let hasTransferEncoding = headers.contains { $0.key.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }
        guard !hasTransferEncoding else {
            return nil
        }
        return RequestHead(method: requestParts[0], path: requestParts[1], headers: headers)
    }

    private static func contentLength(for head: RequestHead) -> Int? {
        let value = head.headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }?.value
        if let value {
            guard let parsed = Int(value), parsed >= 0 else {
                return nil
            }
            return parsed
        }
        return head.method == "POST" ? nil : 0
    }
}
