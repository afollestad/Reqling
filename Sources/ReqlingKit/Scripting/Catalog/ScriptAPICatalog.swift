import ReqlingScriptProtocol

/// Every name a script can reach, typed: `rq`, `pm`, and the globals, each member with its phases and protocols. The
/// runtime (`Sources/ReqlingScriptRunner/Runtime/`) implements exactly this, which `ScriptRuntimeConformanceTests`
/// checks both ways; completion, hover, warnings, and the API reference all read it, so they describe what runs.
public struct ScriptAPICatalog: Sendable {
    public static let standard = ScriptAPICatalog(
        globals: Self.globalMembers,
        types: Self.reqlingTypes + Self.responseTypes + Self.postmanTypes + Self.libraryTypes
    )

    /// What a script names without a receiver.
    public let globals: [ScriptMember]
    public let types: [String: ScriptType]

    init(globals: [ScriptMember], types: [ScriptType]) {
        self.globals = globals
        self.types = Dictionary(types.map { ($0.name, $0) }) { first, _ in first }
    }

    public func type(_ name: String) -> ScriptType? {
        types[name]
    }
}

/// A kind of object a script holds, such as `rq.request`.
public struct ScriptType: Sendable, Hashable {
    public let name: String
    public let summary: String
    public let members: [ScriptMember]
    /// Standard library objects, the vendored libraries, and assertion chains list a documented subset: a name they
    /// don't list is no mistake, and the conformance test doesn't walk them.
    public let isOpen: Bool

    init(_ name: String, _ summary: String, isOpen: Bool = false, members: [ScriptMember]) {
        self.name = name
        self.summary = summary
        self.members = members
        self.isOpen = isOpen
    }

    /// The members named `name`; a response member can differ by protocol (`status` is a string for HTTP and an
    /// object for gRPC), so there may be several.
    public func members(named name: String) -> [ScriptMember] {
        members.filter { $0.name == name }
    }
}

/// Which protocols a member applies to. A request member's HTTP applies to both an HTTP response and an event stream,
/// since which one arrives isn't known before the request.
public typealias ScriptProtocols = Set<ScriptResponseKind>

public struct ScriptMember: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case property
        case method([ScriptParameter])
    }

    public enum Availability: Sendable, Hashable {
        case supported
        /// A Postman name that works, documented by its Reqling equivalent.
        case compatibility(rqEquivalent: String)
        /// It exists only to throw a clear error naming why.
        case unsupported(reason: String)
    }

    public let name: String
    public let kind: Kind
    /// A property's type, or what a method returns.
    public let type: ScriptValueType
    /// The type of the function's own properties, for a function that has them (`rq.test.skip`).
    public let functionType: String?
    public let summary: String
    /// When reading it works; outside these it throws, or its calls do.
    public let phases: Set<ScriptPhase>
    /// `nil` for every protocol.
    public let protocols: ScriptProtocols?
    public let availability: Availability

    init(
        name: String,
        kind: Kind,
        type: ScriptValueType,
        functionType: String? = nil,
        summary: String,
        phases: Set<ScriptPhase> = Set(ScriptPhase.allCases),
        protocols: ScriptProtocols? = nil,
        availability: Availability = .supported
    ) {
        self.name = name
        self.kind = kind
        self.type = type
        self.functionType = functionType
        self.summary = summary
        self.phases = phases
        self.protocols = protocols
        self.availability = availability
    }

    public var isMethod: Bool {
        if case .method = kind {
            return true
        }
        return false
    }

    public var parameters: [ScriptParameter] {
        if case .method(let parameters) = kind {
            return parameters
        }
        return []
    }

    /// As hover cards and the reference show it: `get(name: string): string | undefined`.
    public var signature: String {
        switch kind {
        case .property:
            return "\(name): \(type.description)"
        case .method(let parameters):
            let list = parameters.map { "\($0.name)\($0.isOptional ? "?" : ""): \($0.type.description)" }.joined(separator: ", ")
            return "\(name)(\(list)): \(type.description)"
        }
    }

    /// Whether the member applies to a script in `phase` whose request or response is one of `protocols` (`nil` when
    /// that isn't known, as for a folder's script, which runs for every protocol).
    public func applies(to phase: ScriptPhase, protocols context: ScriptProtocols?) -> Bool {
        guard phases.contains(phase) else {
            return false
        }
        guard let protocols, let context else {
            return true
        }
        return !protocols.isDisjoint(with: context)
    }
}

public struct ScriptParameter: Sendable, Hashable {
    public let name: String
    public let type: ScriptValueType
    public let isOptional: Bool
    /// What completion offers inside this argument's string.
    public let completion: ScriptArgumentCompletion?

    init(_ name: String, _ type: ScriptValueType, isOptional: Bool = false, completion: ScriptArgumentCompletion? = nil) {
        self.name = name
        self.type = type
        self.isOptional = isOptional
        self.completion = completion
    }
}

/// Names completion offers inside a string argument.
public enum ScriptArgumentCompletion: Sendable, Hashable {
    /// Variable names from where the receiver reads.
    case variableName(ScriptVariableSource)
}

/// Where a variable accessor reads.
public enum ScriptVariableSource: Sendable, Hashable {
    case environment
    case defaultEnvironment
    case globals
    /// Every layer, as `{{name}}` resolves.
    case all
}

public indirect enum ScriptValueType: Sendable, Hashable, CustomStringConvertible {
    case named(String)
    case string
    case number
    case boolean
    case void
    case any
    case object
    case function
    case promise
    case array(ScriptValueType)
    case optional(ScriptValueType)
    /// JSON parsed from the response, whose keys come from this request's latest response.
    case responseJSON

    public var description: String {
        switch self {
        case .named(let name): name
        case .string: "string"
        case .number: "number"
        case .boolean: "boolean"
        case .void: "void"
        case .any: "any"
        case .object: "object"
        case .function: "function"
        case .promise: "Promise"
        case .array(let element): "\(element.description)[]"
        case .optional(let wrapped): "\(wrapped.description) | null"
        case .responseJSON: "any"
        }
    }

    /// The named type behind this one, through optionals.
    public var namedType: String? {
        switch self {
        case .named(let name): name
        case .optional(let wrapped): wrapped.namedType
        default: nil
        }
    }
}

extension ScriptMember {
    static func property(
        _ name: String,
        _ type: ScriptValueType,
        _ summary: String,
        phases: Set<ScriptPhase> = Set(ScriptPhase.allCases),
        protocols: ScriptProtocols? = nil,
        availability: Availability = .supported
    ) -> ScriptMember {
        ScriptMember(name: name, kind: .property, type: type, summary: summary, phases: phases, protocols: protocols, availability: availability)
    }

    static func method(
        _ name: String,
        _ parameters: [ScriptParameter] = [],
        returns type: ScriptValueType,
        _ summary: String,
        functionType: String? = nil,
        phases: Set<ScriptPhase> = Set(ScriptPhase.allCases),
        protocols: ScriptProtocols? = nil,
        availability: Availability = .supported
    ) -> ScriptMember {
        ScriptMember(
            name: name,
            kind: .method(parameters),
            type: type,
            functionType: functionType,
            summary: summary,
            phases: phases,
            protocols: protocols,
            availability: availability
        )
    }

    /// A Postman name that works like its Reqling equivalent.
    func postman(_ equivalent: String) -> ScriptMember {
        ScriptMember(
            name: name,
            kind: kind,
            type: type,
            functionType: functionType,
            summary: summary,
            phases: phases,
            protocols: protocols,
            availability: .compatibility(rqEquivalent: equivalent)
        )
    }

    /// A Postman name Reqling refuses with a clear error.
    static func unsupported(_ name: String, _ reason: String, isMethod: Bool = false) -> ScriptMember {
        ScriptMember(
            name: name,
            kind: isMethod ? .method([]) : .property,
            type: isMethod ? .void : .object,
            summary: "Not supported in Reqling: \(reason).",
            availability: .unsupported(reason: reason)
        )
    }
}

extension Set where Element == ScriptPhase {
    static let pre: Set<ScriptPhase> = [.preRequest]
    static let post: Set<ScriptPhase> = [.postResponse]
}

extension Set where Element == ScriptResponseKind {
    /// HTTP's request members, which an event stream's request shares.
    static let http: ScriptProtocols = [.http, .eventStream]
    static let withQuery: ScriptProtocols = [.http, .eventStream, .webSocket]
}
