import ReqlingScriptProtocol

/// The request as the phase's scripts see it. A pre-request script's change applies here, so later levels see it, and
/// is reported for Reqling to apply to what it sends; post-response scripts can only read.
final class ScriptRequestModel {
    private(set) var snapshot: ScriptRequestSnapshot
    private let phase: ScriptPhase
    private let limits: ScriptLimits
    private let events: EventWriter
    private var changes = 0

    init(snapshot: ScriptRequestSnapshot, phase: ScriptPhase, limits: ScriptLimits, events: EventWriter) {
        self.snapshot = snapshot
        self.phase = phase
        self.limits = limits
        self.events = events
    }

    func rows(_ target: ScriptRequestChange.Target) -> [ScriptRow] {
        switch target {
        case .header: snapshot.headers
        case .query: snapshot.query
        case .pathVariable: snapshot.pathVariables
        }
    }

    func apply(_ change: ScriptRequestChange) throws(ScriptFailure) {
        guard phase == .preRequest else {
            throw ScriptFailure("Only pre-request scripts can change the request.")
        }
        guard change.target == .header || snapshot.protocolName != "grpc" else {
            let what = change.target == .query ? "query parameters" : "path variables"
            throw ScriptFailure("A gRPC call has no \(what); change rq.request.metadata instead.")
        }
        guard !change.name.isEmpty else {
            let what = switch change.target {
            case .header: "header"
            case .query: "query parameter"
            case .pathVariable: "path variable"
            }
            throw ScriptFailure("A \(what) needs a name.")
        }
        guard changes < limits.requestChanges else {
            throw ScriptFailure("Scripts can change the request at most \(limits.requestChanges) times.")
        }
        changes += 1
        switch change.target {
        case .header:
            change.apply(to: &snapshot.headers, name: \.name, setValue: { $0.value = $1 }, make: ScriptRow.init)
        case .query:
            change.apply(to: &snapshot.query, name: \.name, setValue: { $0.value = $1 }, make: ScriptRow.init)
        case .pathVariable:
            change.apply(to: &snapshot.pathVariables, name: \.name, setValue: { $0.value = $1 }, make: ScriptRow.init)
        }
        events.write(.request(change))
    }
}
