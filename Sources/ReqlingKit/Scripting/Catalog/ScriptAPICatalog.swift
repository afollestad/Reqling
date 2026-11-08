import ReqlingScriptProtocol

/// Every name a script can reach, typed: `rq`, `pm`, and the globals, each member with its phases and protocols. The
/// runtime (`Sources/ReqlingScriptRunner/Runtime/`) implements exactly this, which `ScriptRuntimeConformanceTests`
/// checks both ways; completion, hover, warnings, and the API reference all read it, so they describe what runs.
public struct ScriptAPICatalog: Sendable {
    public static let standard = ScriptAPICatalog(
        globals: Self.globalMembers,
        types: Self.reqlingTypes + Self.cookieTypes + Self.responseTypes + Self.fetchTypes + Self.postmanTypes + Self.libraryTypes
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
    /// object for gRPC), so there may be several. Members sharing a name never share a protocol in a phase they share,
    /// so where the protocol is known, one applies.
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
    /// What completion offers in a string written as this property's value, in an options object a script passes
    /// (`{ method: "…" }`).
    public let completion: ScriptArgumentCompletion?

    init(
        name: String,
        kind: Kind,
        type: ScriptValueType,
        functionType: String? = nil,
        summary: String,
        phases: Set<ScriptPhase> = Set(ScriptPhase.allCases),
        protocols: ScriptProtocols? = nil,
        availability: Availability = .supported,
        completion: ScriptArgumentCompletion? = nil
    ) {
        self.name = name
        self.kind = kind
        self.type = type
        self.functionType = functionType
        self.summary = summary
        self.phases = phases
        self.protocols = protocols
        self.availability = availability
        self.completion = completion
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
            return "\(name)(\(parameters.map(\.signature).joined(separator: ", "))): \(type.description)"
        }
    }

    /// Whether the member applies to a script in `phase` whose request or response is one of `protocols` (`nil` when
    /// that isn't known, as for a folder's script, which runs for every protocol).
    public func applies(to phase: ScriptPhase, protocols context: ScriptProtocols?) -> Bool {
        phases.contains(phase) && matches(protocols: context)
    }

    /// Whether the member is one for `protocols`, whatever the phase.
    public func matches(protocols context: ScriptProtocols?) -> Bool {
        guard let protocols, let context else {
            return true
        }
        return !protocols.isDisjoint(with: context)
    }

    /// The parameter at `position` of the function a script passes as argument `argument`, as the API calls it, when
    /// that argument is a callback (`ScriptValueType.callback`).
    public func callbackParameter(argument: Int, position: Int) -> ScriptParameter? {
        let parameters = parameters
        let parameter = argument < parameters.count ? parameters[argument] : parameters.last.flatMap { $0.isRest ? $0 : nil }
        guard case .callback(let arguments)? = parameter?.type, arguments.indices.contains(position) else {
            return nil
        }
        return arguments[position]
    }
}

public struct ScriptParameter: Sendable, Hashable {
    public let name: String
    /// Its type; for a rest parameter, the type of each argument it takes.
    public let type: ScriptValueType
    /// What the argument is, as parameter hints show it under the signature. Required, so every parameter added to
    /// the catalog is described there.
    public let summary: String
    public let isOptional: Bool
    /// Takes every argument from here on, as `console.log`'s values do, so parameter hints keep it highlighted.
    public let isRest: Bool
    /// What completion offers inside this argument's string.
    public let completion: ScriptArgumentCompletion?

    init(
        _ name: String,
        _ type: ScriptValueType,
        _ summary: String,
        isOptional: Bool = false,
        isRest: Bool = false,
        completion: ScriptArgumentCompletion? = nil
    ) {
        self.name = name
        self.type = type
        self.summary = summary
        self.isOptional = isOptional
        self.isRest = isRest
        self.completion = completion
    }

    /// As signatures show it: `name?: string`, or `...values: any[]` for a rest parameter.
    public var signature: String {
        isRest ? "...\(name): \(ScriptValueType.array(type).description)" : "\(name)\(isOptional ? "?" : ""): \(type.description)"
    }
}

/// What completion offers inside a string: an argument's, or a value in an options object.
public enum ScriptArgumentCompletion: Sendable, Hashable {
    /// Variable names from where the receiver reads.
    case variableName(ScriptVariableSource)
    /// These values, as an enum's. `exhaustive` when they're the only ones the runtime takes, so the editor warns of any
    /// other a script writes (a cookie's `sameSite`); otherwise they're suggestions (an HTTP method, where any token
    /// works). They're compared ignoring case unless `matchesCase`, for a runtime that takes them exactly as written
    /// (`require`'s library names).
    case choices([String], exhaustive: Bool = false, matchesCase: Bool = false)
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
    /// What a promise settles with, which `await` gives.
    case promise(ScriptValueType)
    case array(ScriptValueType)
    case optional(ScriptValueType)
    /// Any one of these, such as a URL or a request object.
    case oneOf([ScriptValueType])
    /// JSON parsed from the response, whose keys come from this request's latest response.
    case responseJSON
    /// A function the API calls with these arguments, such as `rq.onEvent`'s handler; a script's function written as
    /// that argument gets them as its parameters. `ScriptRuntimeConformanceTests` calls each one to check them.
    case callback([ScriptParameter])

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
        case .promise(let value): "Promise<\(value.description)>"
        case .array(let element): "\(element.description)[]"
        case .optional(let wrapped): "\(wrapped.description) | null"
        case .oneOf(let types): types.map(\.description).joined(separator: " | ")
        case .responseJSON: "any"
        case .callback(let parameters): "(\(parameters.map(\.signature).joined(separator: ", "))) => void"
        }
    }

    /// Every named type this one mentions, through arrays, optionals, promises, alternatives, and a callback's
    /// parameters.
    public var referencedNames: [String] {
        switch self {
        case .named(let name): [name]
        case .array(let wrapped), .optional(let wrapped), .promise(let wrapped): wrapped.referencedNames
        case .oneOf(let types): types.flatMap(\.referencedNames)
        case .callback(let parameters): parameters.flatMap(\.type.referencedNames)
        default: []
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
        availability: Availability = .supported,
        completion: ScriptArgumentCompletion? = nil
    ) -> ScriptMember {
        ScriptMember(
            name: name, kind: .property, type: type, summary: summary, phases: phases, protocols: protocols, availability: availability,
            completion: completion
        )
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
            availability: .compatibility(rqEquivalent: equivalent),
            completion: completion
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
    static let stream: Set<ScriptPhase> = [.stream]
    static let post: Set<ScriptPhase> = [.postResponse]
    /// What a stream script reads of a response, which it opened with, and a post-response script reads whole.
    static let opened: Set<ScriptPhase> = [.stream, .postResponse]

    /// As notes and warnings name them, in running order: "stream and post-response".
    var listed: String {
        ScriptPhase.allCases.filter(contains).map { $0.title.lowercased() }.joined(separator: " and ")
    }
}

extension Set where Element == ScriptResponseKind {
    /// As notes and warnings name them: "HTTP and WebSocket". An event stream is an HTTP response, so HTTP covers it.
    var listed: String {
        [(ScriptResponseKind.http, "HTTP"), (.grpc, "gRPC"), (.webSocket, "WebSocket")]
            .filter { contains($0.0) || ($0.0 == .http && contains(.eventStream)) }
            .map(\.1)
            .joined(separator: " and ")
    }

    /// HTTP's request members, which an event stream's request shares.
    static let http: ScriptProtocols = [.http, .eventStream]
    static let withQuery: ScriptProtocols = [.http, .eventStream, .webSocket]
    /// Requests sent to a URL, whose cookies `rq.cookies` reads; a gRPC call has none.
    static let withCookies: ScriptProtocols = [.http, .eventStream, .webSocket]
}
