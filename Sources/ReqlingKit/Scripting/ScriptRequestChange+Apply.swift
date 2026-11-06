import Foundation
import ReqlingScriptProtocol

/// A pre-request script's header and query changes, applied for one run: to the request it sends, and to the masked
/// record of what was sent, which marks the rows scripts touched.
extension RequestKind {
    /// The request with a pre-request script's header and query changes applied, for this run only. Changes reach only
    /// enabled rows, the ones a script saw; removing a header also turns off Reqling's automatic one by that name, so
    /// `remove("User-Agent")` does what it says.
    func applying(_ changes: [ScriptRequestChange]) -> RequestKind {
        guard !changes.isEmpty else {
            return self
        }
        switch self {
        case .http(var spec):
            spec.headers = Self.apply(changes, target: .header, to: spec.headers)
            spec.queryParameters = Self.apply(changes, target: .query, to: spec.queryParameters)
            spec.disabledAutoHeaders = Self.disabling(changes, in: spec.disabledAutoHeaders)
            return .http(spec)
        case .grpc(var spec):
            spec.metadata = Self.apply(changes, target: .header, to: spec.metadata)
            return .grpc(spec)
        case .webSocket(var spec):
            spec.headers = Self.apply(changes, target: .header, to: spec.headers)
            spec.queryParameters = Self.apply(changes, target: .query, to: spec.queryParameters)
            spec.disabledAutoHeaders = Self.disabling(changes, in: spec.disabledAutoHeaders)
            return .webSocket(spec)
        }
    }

    private static func apply(_ changes: [ScriptRequestChange], target: ScriptRequestChange.Target, to rows: [KeyValuePair]) -> [KeyValuePair] {
        var enabled = rows.filter(\.isEnabled)
        for change in changes where change.target == target {
            change.apply(to: &enabled, name: \.key, setValue: { $0.value = $1 }, make: { KeyValuePair(key: $0, value: $1) })
        }
        return enabled + rows.filter { !$0.isEnabled }
    }

    private static func disabling(_ changes: [ScriptRequestChange], in disabled: [String]) -> [String] {
        var names = disabled
        for change in changes where change.target == .header && change.operation == .remove {
            let name = change.name.lowercased()
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}

extension PreparedHTTPRequest {
    /// Takes the run's script-aware masking, and marks the rows a pre-request script added or replaced, so the Request
    /// tab can label them. A secret a script wrote into a row literally, which template masking never saw, is masked
    /// there, and its header counts as a credential, stripped on a redirect to another origin.
    mutating func markScriptChanges(_ changes: [ScriptRequestChange], redaction: SecretRedaction) {
        self.redaction = redaction
        let written = changes.filter { $0.operation != .remove }
        let headers = Set(written.filter { $0.target == .header }.map { $0.name.lowercased() })
        let query = Set(written.filter { $0.target == .query }.map(\.name))
        for index in summary.headers.indices where headers.contains(summary.headers[index].key.lowercased()) {
            let masked = redaction.apply(summary.headers[index].value)
            if masked != summary.headers[index].value {
                summary.headers[index].value = masked
                credentialHeaderNames.insert(summary.headers[index].key.lowercased())
            }
        }
        if !query.isEmpty, let url = URL(string: summary.url) {
            summary.url = redaction.apply(to: url)
        }
        summary.scriptChangedHeaders = headers.isEmpty ? nil : headers.sorted()
        summary.scriptChangedQuery = query.isEmpty ? nil : query.sorted()
    }
}

extension GRPCEndpoint {
    /// Marks the metadata a pre-request script added or replaced, masking any secret it wrote in literally, as
    /// `PreparedHTTPRequest.markScriptChanges` does for headers.
    mutating func markScriptChanges(_ changes: [ScriptRequestChange], redaction: SecretRedaction) {
        let names = Set(changes.filter { $0.operation != .remove && $0.target == .header }.map { $0.name.lowercased() })
        for index in shownMetadata.indices where names.contains(shownMetadata[index].key) {
            shownMetadata[index].value = redaction.apply(shownMetadata[index].value)
        }
        scriptChangedMetadata = names.isEmpty ? nil : names.sorted()
    }
}
