/// How a request's most recent run went, for filtering and status display.
public enum RunOutcomeKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// The server answered below 400.
    case succeeded
    /// The server answered 400 or above, or the run failed or was cancelled.
    case failed
    /// The request has not been run on this Mac.
    case notSent
}

/// Narrows the sidebar beyond its text query. An empty set means no constraint on that dimension.
public struct RequestFilter: Hashable, Sendable {
    public enum MethodGroup: Hashable, Sendable, CaseIterable {
        case get
        case post
        case put
        case patch
        case delete
        /// HEAD, OPTIONS, TRACE, and custom methods.
        case other

        public init(_ method: HTTPMethod) {
            switch method {
            case .get: self = .get
            case .post: self = .post
            case .put: self = .put
            case .patch: self = .patch
            case .delete: self = .delete
            default: self = .other
            }
        }
    }

    public var methods: Set<MethodGroup>
    public var outcomes: Set<RunOutcomeKind>

    public init(methods: Set<MethodGroup> = [], outcomes: Set<RunOutcomeKind> = []) {
        self.methods = methods
        self.outcomes = outcomes
    }

    public static let none = RequestFilter()

    public var isActive: Bool {
        !methods.isEmpty || !outcomes.isEmpty
    }

    func admits(_ request: RequestItem, outcome: RunOutcomeKind) -> Bool {
        if !methods.isEmpty {
            guard let method = request.kind.httpSpec?.method, methods.contains(MethodGroup(method)) else {
                return false
            }
        }
        return outcomes.isEmpty || outcomes.contains(outcome)
    }
}
