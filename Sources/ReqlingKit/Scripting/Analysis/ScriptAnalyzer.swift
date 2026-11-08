import Foundation
import ReqlingScriptProtocol

/// Where a script runs, for what applies to it there.
public struct ScriptAnalysisContext: Sendable {
    public var phase: ScriptPhase
    /// The request's protocols; `nil` for a folder's or the project's script, which runs for every protocol.
    public var protocols: ScriptProtocols?
    /// The variable names a string argument completes with, by where its accessor reads.
    public var variables: [ScriptVariableSource: [String]]
    /// The latest response's JSON, for `rq.response.json()`'s keys.
    public var responseShape: ScriptJSONShape?

    public init(
        phase: ScriptPhase,
        protocols: ScriptProtocols? = nil,
        variables: [ScriptVariableSource: [String]] = [:],
        responseShape: ScriptJSONShape? = nil
    ) {
        self.phase = phase
        self.protocols = protocols
        self.variables = variables
        self.responseShape = responseShape
    }

    /// What a request of `kind` may get back: an HTTP request's response may turn out to be an event stream.
    public static func protocols(for kind: RequestKind.Name) -> ScriptProtocols {
        switch kind {
        case .http: [.http, .eventStream]
        case .grpc: [.grpc]
        case .webSocket: [.webSocket]
        }
    }
}

/// Completion, hover, and warnings for a script, from `ScriptAPICatalog`, so they describe what runs. A member chain
/// resolves through the catalog's types, through simple aliases (`const r = rq.response`) and destructuring, and into
/// the latest response's JSON keys. `pm` resolves for hover and warnings but is never offered: scripts written here
/// use `rq`, and `pm` is there for scripts brought from Postman.
public struct ScriptAnalyzer {
    let context: ScriptAnalysisContext
    let catalog: ScriptAPICatalog
    let expressions: ScriptExpressions

    public init(text: String, context: ScriptAnalysisContext, catalog: ScriptAPICatalog = .standard) {
        self.context = context
        self.catalog = catalog
        expressions = ScriptExpressions(text: text)
    }
}

/// What a chain's value is, as far as the catalog knows.
enum ScriptResolvedValue {
    case typed(ScriptValueType)
    /// A method named but not yet called: calling it gives its return type, and some have properties of their own
    /// (`rq.test.skip`).
    case method(ScriptMember)
    /// A path into the response's JSON: keys, and `nil` for an array's items.
    case json([String?])
    case unknown
}

/// Why a member a chain names doesn't work where the script runs.
enum ScriptStepProblem: Equatable {
    case missing
    case phases(Set<ScriptPhase>)
    case protocols(ScriptProtocols)
    case unsupported(String)
}

/// One named member along a resolved chain.
struct ScriptResolvedStep {
    let name: String
    let range: NSRange
    /// The chain up to the member, as messages name it: `rq.request`.
    let receiverText: String
    let receiver: ScriptType?
    let member: ScriptMember?
    let problem: ScriptStepProblem?
}

extension ScriptAnalyzer {
    /// Bindings resolve through at most this many aliases, so `let a = b; let b = a` ends.
    private static let aliasDepth = 8

    /// The chain's value and each member it named, resolved where it runs.
    func resolve(
        _ chain: ScriptMemberChain,
        bindings: [String: ScriptMemberChain],
        depth: Int = 0
    ) -> (value: ScriptResolvedValue, steps: [ScriptResolvedStep]) {
        var (value, text) = rootValue(chain, bindings: bindings, depth: depth)
        var steps: [ScriptResolvedStep] = []
        for step in chain.steps {
            switch step {
            case .name(let name, let range):
                let lookup = member(name, of: value)
                steps.append(ScriptResolvedStep(
                    name: name,
                    range: range,
                    receiverText: text,
                    receiver: lookup.receiver,
                    member: lookup.member,
                    problem: lookup.problem
                ))
                value = lookup.value
                text += ".\(name)"
            case .call:
                value = called(value)
                text += "()"
            case .index(let key):
                value = indexed(value, key: key)
                text += "[\(key.map { "\"\($0)\"" } ?? "…")]"
            case .parameter(let argument, let position):
                value = callbackParameter(of: value, receiver: steps.last?.receiver, argument: argument, position: position)
                    .map { .typed($0.type) } ?? .unknown
            case .awaited:
                // Awaiting anything but a promise gives the value itself.
                if case .typed(.promise(let settled)) = value {
                    value = .typed(settled)
                }
            }
        }
        return (value, steps)
    }

    /// The parameter at `position` of the function passed as argument `argument` to `value`'s method, as the API calls
    /// it. `nil` when that argument is no callback, or when the methods sharing its name call it with different types,
    /// as `rq.onMessage` does in a folder's script, whose protocol isn't known: the parameter is then left untyped,
    /// neither completing nor warning.
    func callbackParameter(of value: ScriptResolvedValue, receiver: ScriptType?, argument: Int, position: Int) -> ScriptParameter? {
        guard case .method(let method) = value else {
            return nil
        }
        let named = receiver?.members(named: method.name) ?? [method]
        let applicable = named.filter { $0.applies(to: context.phase, protocols: context.protocols) }
        let parameters = (applicable.isEmpty ? [method] : applicable).map { $0.callbackParameter(argument: argument, position: position) }
        guard let first = parameters.first, let parameter = first, parameters.allSatisfy({ $0?.type == parameter.type }) else {
            return nil
        }
        return parameter
    }

    /// The global or alias a chain starts from, and how messages name it: an alias by what it stands for. Anything else
    /// is a local the catalog can't know.
    private func rootValue(
        _ chain: ScriptMemberChain,
        bindings: [String: ScriptMemberChain],
        depth: Int
    ) -> (value: ScriptResolvedValue, text: String) {
        if let bound = bindings[chain.root] {
            guard depth < Self.aliasDepth else {
                return (.unknown, chain.root)
            }
            let resolved = resolve(bound, bindings: bindings, depth: depth + 1)
            // A handler's parameter is named as the script names it: `event`, not `rq.onEvent`.
            if case .parameter = bound.steps.last {
                return (resolved.value, chain.root)
            }
            let text = resolved.steps.last.map { "\($0.receiverText).\($0.name)" } ?? bound.root
            return (resolved.value, bound.steps.contains { if case .name = $0 { true } else { false } } ? text : chain.root)
        }
        guard let global = catalog.globals.first(where: { $0.name == chain.root }) else {
            return (.unknown, chain.root)
        }
        return (global.isMethod ? .method(global) : .typed(global.type), chain.root)
    }

    /// What `name` is on `value`: a member the catalog lists, with any problem using it where the script runs.
    private struct MemberLookup {
        var value: ScriptResolvedValue = .unknown
        var receiver: ScriptType?
        var member: ScriptMember?
        var problem: ScriptStepProblem?
    }

    private func member(_ name: String, of value: ScriptResolvedValue) -> MemberLookup {
        let receiver: ScriptType
        switch value {
        case .typed(.responseJSON):
            return MemberLookup(value: .json([name]))
        case .json(let path):
            return MemberLookup(value: .json(path + [name]))
        case .typed(let type):
            guard let found = type.namedType.flatMap(catalog.type) else {
                return MemberLookup()
            }
            receiver = found
        case .method(let method):
            guard let found = method.functionType.flatMap(catalog.type) else {
                return MemberLookup()
            }
            receiver = found
        case .unknown:
            return MemberLookup()
        }
        let candidates = receiver.members(named: name)
        let applicable = candidates.filter { $0.applies(to: context.phase, protocols: context.protocols) }
        // Failing that, the one for the script's protocol, whose problem is its phase.
        guard let member = applicable.first ?? candidates.first(where: { $0.matches(protocols: context.protocols) }) ?? candidates.first else {
            return MemberLookup(receiver: receiver, problem: receiver.isOpen ? nil : .missing)
        }
        var value: ScriptResolvedValue = member.isMethod ? .method(member) : .typed(member.type)
        // Where the protocol isn't known, members sharing the name may hold different types, so what follows can't be
        // checked: `rq.response.messages` in a folder's script is gRPC's or a WebSocket's.
        if !member.isMethod, Set(applicable.map(\.type)).count > 1 {
            value = .unknown
        }
        return MemberLookup(value: value, receiver: receiver, member: member, problem: problem(with: member, among: candidates))
    }

    private func problem(with member: ScriptMember, among candidates: [ScriptMember]) -> ScriptStepProblem? {
        if case .unsupported(let reason) = member.availability {
            return .unsupported(reason)
        }
        if !member.phases.contains(context.phase) {
            return .phases(member.phases)
        }
        if !member.applies(to: context.phase, protocols: context.protocols) {
            // Only the protocols it works for here: in a stream script, `rq.response.status` is HTTP's alone.
            let here = candidates.filter { $0.phases.contains(context.phase) }
            return .protocols(here.reduce(into: ScriptProtocols()) { $0.formUnion($1.protocols ?? []) })
        }
        return nil
    }

    private func called(_ value: ScriptResolvedValue) -> ScriptResolvedValue {
        if case .method(let method) = value {
            return .typed(method.type)
        }
        return .unknown
    }

    /// An array's item, or a step into the response's JSON; a number key is an array's item.
    private func indexed(_ value: ScriptResolvedValue, key: String?) -> ScriptResolvedValue {
        let jsonKey = key.flatMap { Int($0) == nil ? $0 : nil }
        switch value {
        case .typed(.array(let element)):
            return .typed(element)
        case .typed(.responseJSON):
            return .json([jsonKey])
        case .json(let path):
            return .json(path + [jsonKey])
        default:
            return .unknown
        }
    }
}
