import Foundation

/// One run of a request: what was sent (masked) and what came back, or why it failed.
public struct RequestExchange: Hashable, Sendable, Codable {
    public var projectID: ProjectID
    public var requestID: RequestNodeID
    public var startedAt: Date
    public var environmentName: String?
    public var request: ResolvedHTTPRequest?
    public var outcome: Outcome
    public var unresolvedVariables: [String]
    /// The stored HTTP body, or the stored gRPC messages, were cut to fit the cache (`ResponseCache.bodyLimit` and
    /// `grpcMessageLimit`); the run itself saw them all.
    public var isBodyTruncated: Bool

    public enum Outcome: Hashable, Sendable, Codable {
        case response(HTTPResponseRecord)
        /// A gRPC call that reached the server, whatever its status; a call that never connected is a `failure`.
        case grpc(GRPCCallRecord)
        case failure(RunFailure)
    }

    public init(
        projectID: ProjectID,
        requestID: RequestNodeID,
        startedAt: Date,
        environmentName: String?,
        request: ResolvedHTTPRequest?,
        outcome: Outcome,
        unresolvedVariables: [String] = [],
        isBodyTruncated: Bool = false
    ) {
        self.projectID = projectID
        self.requestID = requestID
        self.startedAt = startedAt
        self.environmentName = environmentName
        self.request = request
        self.outcome = outcome
        self.unresolvedVariables = unresolvedVariables
        self.isBodyTruncated = isBodyTruncated
    }

    public var response: HTTPResponseRecord? {
        if case .response(let response) = outcome {
            return response
        }
        return nil
    }

    public var grpc: GRPCCallRecord? {
        if case .grpc(let call) = outcome {
            return call
        }
        return nil
    }

    public var failure: RunFailure? {
        if case .failure(let failure) = outcome {
            return failure
        }
        return nil
    }

    public var outcomeKind: RunOutcomeKind {
        switch outcome {
        case .response(let response): response.statusCode < 400 ? .succeeded : .failed
        case .grpc(let call): call.status?.isOK == true ? .succeeded : .failed
        case .failure: .failed
        }
    }
}

public struct RunFailure: Hashable, Sendable, Codable, Error {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The request could not be built: a bad URL, a missing file, unresolved variables.
        case invalidRequest
        case tls
        case cancelled
        case timedOut
        case transport
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// The failure with the run's secrets masked. Transport and TLS messages quote hosts and URLs, which may have
    /// come from a secret variable.
    func redacting(_ redaction: SecretRedaction) -> RunFailure {
        RunFailure(kind: kind, message: redaction.apply(message))
    }

    /// Unresolved `{{variables}}` stop a run before anything is sent, unless `RunOptions.allowUnresolved` is set.
    static func undefinedVariables(_ names: [String]) -> RunFailure {
        let list = names.map { "{{\($0)}}" }.joined(separator: ", ")
        return RunFailure(kind: .invalidRequest, message: "Undefined variables: \(list). Define them in an environment, or remove them.")
    }

    /// A gRPC call that ended without a status; TLS failures of either kind share `.tls`, as HTTP's do.
    init(_ error: GRPCCallError) {
        let kind: Kind = switch error {
        case .invalidRequest: .invalidRequest
        case .connectionFailed: .transport
        case .untrustedServer, .tlsFailed: .tls
        case .cancelled: .cancelled
        }
        self.init(kind: kind, message: error.localizedDescription)
    }
}

/// Keeps each request's latest exchange on disk so the response pane survives a relaunch. Bodies over `bodyLimit`
/// are cut, and the exchange says so.
public struct ResponseCache: Sendable {
    public static let bodyLimit = 5 * 1024 * 1024
    /// Each cached gRPC message's JSON is cut to this; all of a call's messages together share `bodyLimit`.
    public static let grpcMessageLimit = 64 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(_ request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        guard let data = try? Data(contentsOf: fileURL(request, in: project)) else {
            return nil
        }
        return try? JSONDecoder().decode(RequestExchange.self, from: data)
    }

    /// Every request's latest outcome in a project, from a small index kept beside the exchanges, so filtering by
    /// result never decodes a response body.
    public func outcomes(in project: ProjectID) -> [RequestNodeID: RunOutcomeKind] {
        guard let data = try? Data(contentsOf: indexURL(for: project)),
              let index = try? JSONDecoder().decode([String: RunOutcomeKind].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: index.compactMap { key, value in RequestNodeID(string: key).map { ($0, value) } })
    }

    public func save(_ exchange: RequestExchange) {
        var stored = exchange
        switch exchange.outcome {
        case .response(var response) where response.body.count > Self.bodyLimit:
            response.body = response.body.prefix(Self.bodyLimit)
            stored.outcome = .response(response)
            stored.isBodyTruncated = true
        case .grpc(let call):
            let fitted = call.fittingCache(messageLimit: Self.grpcMessageLimit, totalLimit: Self.bodyLimit)
            if fitted.wasCut {
                stored.outcome = .grpc(fitted.record)
                stored.isBodyTruncated = true
            }
        default:
            break
        }
        let url = fileURL(exchange.requestID, in: exchange.projectID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
            var index = Dictionary(uniqueKeysWithValues: outcomes(in: exchange.projectID).map { ($0.key.description, $0.value) })
            index[exchange.requestID.description] = exchange.outcomeKind
            try JSONEncoder().encode(index).write(to: indexURL(for: exchange.projectID), options: .atomic)
        } catch {
            // The cache only restores the last response after a relaunch; the live exchange is unaffected.
        }
    }

    public func removeAll(in project: ProjectID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(project.description, isDirectory: true))
    }

    private func indexURL(for project: ProjectID) -> URL {
        directory.appendingPathComponent(project.description, isDirectory: true).appendingPathComponent("index.json")
    }

    private func fileURL(_ request: RequestNodeID, in project: ProjectID) -> URL {
        directory
            .appendingPathComponent(project.description, isDirectory: true)
            .appendingPathComponent("\(request).json")
    }
}
