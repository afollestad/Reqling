import Foundation

/// One problem protoc reported, or one Reqling found while loading a schema.
public struct ProtocDiagnostic: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    /// Relative to the root the file lives under, or as protoc printed it when under none; `nil` for a line naming
    /// no file.
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let message: String
    /// The file on disk, when `file` resolves under one of the roots, so the UI can reveal it.
    public let url: URL?

    public init(severity: Severity = .error, file: String? = nil, line: Int? = nil, column: Int? = nil, message: String, url: URL? = nil) {
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.url = url
    }

    /// `file:line:column: message`, the form protoc and editors print.
    public var description: String {
        guard let file else {
            return message
        }
        let position = [line, column].compactMap { $0.map(String.init) }
        return ([file] + position).joined(separator: ":") + ": " + message
    }
}

extension ProtocDiagnostic {
    /// Parses protoc's stderr. `file:line:column: message` lines become positioned diagnostics, with a `warning: `
    /// prefix setting the severity; any other non-empty line stays as raw text, since protoc reports problems like
    /// "Could not make proto path relative" with no position at all.
    static func parse(_ output: String, roots: [URL]) -> [ProtocDiagnostic] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                return nil
            }
            guard let match = line.wholeMatch(of: /(.+?):(\d+):(\d+): (.*)/) else {
                return ProtocDiagnostic(message: line)
            }
            var message = String(match.4)
            var severity = Severity.error
            if message.hasPrefix("warning: ") {
                severity = .warning
                message.removeFirst("warning: ".count)
            }
            let (file, url) = locate(String(match.1), under: roots)
            return ProtocDiagnostic(severity: severity, file: file, line: Int(match.2), column: Int(match.3), message: message, url: url)
        }
    }

    /// The root-relative path and the file on disk. protoc prints the disk path, which is absolute for absolute
    /// roots; a relative one is searched in `-I` order, as protoc itself does.
    private static func locate(_ path: String, under roots: [URL]) -> (file: String, url: URL?) {
        guard path.hasPrefix("/") else {
            let url = roots.map { $0.appendingPathComponent(path) }.first { FileManager.default.fileExists(atPath: $0.path) }
            return (path, url)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        for root in roots {
            let prefix = root.standardizedFileURL.path + "/"
            if url.path.hasPrefix(prefix) {
                return (String(url.path.dropFirst(prefix.count)), url)
            }
        }
        return (path, url)
    }
}
