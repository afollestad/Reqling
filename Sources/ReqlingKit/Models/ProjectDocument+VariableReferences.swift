import Foundation
import ReqlingScriptProtocol
import ReqlingTemplating

/// The variables a project names that something outside it may define, for sharing it: whoever it's shared with
/// resolves them against their own Global, which the project doesn't carry.
public struct VariableReferences: Equatable, Sendable {
    /// Names `{{name}}` resolves anywhere in the project, or its scripts read from every layer or an environment.
    public var names: Set<String> = []
    /// Names its scripts read only through `rq.globals`, which a variable in the project can't stand in for.
    public var globalsOnly: Set<String> = []
}

extension ProjectDocument {
    /// Every `{{name}}` in the project's requests, auth, settings, and environments, and in its scripts' strings, and
    /// every name its scripts read with a literal string. Dynamic names (`{{$guid}}`) aren't variables, so aren't here.
    public func variableReferences() -> VariableReferences {
        var texts: [String] = []
        var scripts: [ScriptSet] = [scripts]
        Self.collectStrings(of: auth, into: &texts)
        Self.collectStrings(of: tls, into: &texts)
        Self.collectStrings(of: grpc, into: &texts)
        for environment in allEnvironments {
            Self.collectStrings(of: environment, into: &texts)
        }
        func visit(_ nodes: [RequestNode]) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    Self.collectStrings(of: folder.auth, into: &texts)
                    scripts.append(folder.scripts)
                    visit(folder.children)
                case .request(let request):
                    Self.collectStrings(of: request, into: &texts)
                    scripts.append(request.scripts)
                }
            }
        }
        visit(items)
        var references = VariableReferences()
        var fromGlobals: Set<String> = []
        for script in scripts {
            for phase in ScriptPhase.allCases where !script[phase].isEmpty {
                texts.append(script[phase])
                for variable in ScriptAnalyzer.readVariables(in: script[phase]) {
                    if variable.source == .globals {
                        fromGlobals.insert(variable.name)
                    } else {
                        references.names.insert(variable.name)
                    }
                }
            }
        }
        for text in texts {
            references.names.formUnion(TemplateParser.variableNames(in: text))
        }
        references.globalsOnly = fromGlobals.subtracting(references.names)
        return references
    }

    /// Every string `value` encodes to, keys aside.
    private static func collectStrings(of value: some Encodable, into texts: inout [String]) {
        guard let data = try? JSONEncoder().encode(value), let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return
        }
        func walk(_ node: Any) {
            switch node {
            case let text as String:
                texts.append(text)
            case let array as [Any]:
                array.forEach(walk)
            case let object as [String: Any]:
                object.values.forEach(walk)
            default:
                break
            }
        }
        walk(json)
    }
}
