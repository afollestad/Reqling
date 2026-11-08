import Foundation
import ReqlingScriptProtocol
import ReqlingTemplating

/// Postman's pre-request and test scripts as their owner's pre-request and post-response scripts, each checked as the
/// editor checks it (`ScriptProblem.find`), plus what only a whole collection shows: a global an enclosing level's script
/// defines for the scripts below it, which Reqling, running each script on its own, never shares.
extension PostmanPlanner {
    mutating func scripts(_ events: PostmanJSON?, owner: PostmanImportNote.Owner, protocols: ScriptProtocols?) -> ScriptSet {
        var scripts = ScriptSet()
        for event in events?.array ?? [] {
            guard let phase = Self.phase(event["listen"]?.string) else {
                continue
            }
            let source = event["script"]?["exec"]?.lines ?? ""
            guard event["disabled"]?.bool != true else {
                note(owner, .script(phase, line: nil), "Its \(phase.title.lowercased()) script was turned off in Postman, so it isn't imported.")
                continue
            }
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if event["script"]?["src"] != nil {
                    let message = "Its \(phase.title.lowercased()) script loads from a URL, which Reqling doesn't; paste it in."
                    note(owner, .script(phase, line: nil), message)
                }
                continue
            }
            scripts[phase] = scripts[phase].isEmpty ? source : scripts[phase] + "\n\n" + source
        }
        for phase in [ScriptPhase.preRequest, .postResponse] where !scripts[phase].isEmpty {
            hasScripts = true
            for problem in ScriptProblem.find(in: scripts[phase], context: ScriptAnalysisContext(phase: phase, protocols: protocols)) {
                note(owner, .script(phase, line: problem.line), problem.message)
            }
            countGlobalsFromEnclosingScripts(used: scripts[phase])
            // Only a folder's or the project's script runs before others; a request's runs before none.
            if protocols == nil {
                noteSharedPrototypes(in: scripts[phase], phase: phase, owner: owner)
            }
        }
        return scripts
    }

    /// Postman's `listen` values: `prerequest` before the request, `test` after the response.
    private static func phase(_ listen: String?) -> ScriptPhase? {
        switch listen {
        case "prerequest": .preRequest
        case "test": .postResponse
        default: nil
        }
    }

    /// Counts each global that a script here reads without defining, but an enclosing folder's or the project's script
    /// defines for the scripts after it, as Postman's shared sandbox allows (`utils = { … }` in a collection script).
    private mutating func countGlobalsFromEnclosingScripts(used source: String) {
        let expressions = ScriptExpressions(text: source)
        let read = Set(expressions.tokens.indices.compactMap { index -> String? in
            let token = expressions.tokens[index]
            let isMember = index >= 1 && ScriptExpressions.isDot(expressions.tokens[index - 1])
            return token.kind == .identifier && !isMember && !expressions.declaredNames.contains(token.text) ? token.text : nil
        })
        for (owner, shared) in enclosingGlobals {
            for phase in [ScriptPhase.preRequest, .postResponse] {
                for name in (shared[phase] ?? []).filter(read.contains).sorted() {
                    if let index = sharedGlobalUses.firstIndex(where: { $0.owner == owner && $0.phase == phase && $0.name == name }) {
                        sharedGlobalUses[index].users += 1
                    } else {
                        sharedGlobalUses.append(SharedGlobalUse(owner: owner, phase: phase, name: name, users: 1))
                    }
                }
            }
        }
    }

    /// One note per global a level's script shares, on that script, however many scripts below read it.
    mutating func noteSharedGlobalUses() {
        for use in sharedGlobalUses {
            let readers = use.users == 1 ? "a script after it reads it" : "\(use.users) scripts after it read it"
            note(use.owner, .script(use.phase, line: nil), "Its \(use.phase.title.lowercased()) script defines \(use.name) and "
                + "\(readers), but Reqling runs each script on its own; share it through a variable, or define it where it's read.")
        }
    }

    /// What a folder's or the project's script adds to `Object.prototype` never reaches another script in Reqling.
    private mutating func noteSharedPrototypes(in source: String, phase: ScriptPhase, owner: PostmanImportNote.Owner) {
        let tokens = ScriptExpressions(text: source).tokens
        for index in tokens.indices.dropLast(4) where tokens[index].text == "Object" && tokens[index + 2].text == "prototype"
            && ScriptExpressions.isDot(tokens[index + 1]) && ScriptExpressions.isDot(tokens[index + 3]) {
            note(owner, .script(phase, line: nil), "Its \(phase.title.lowercased()) script adds Object.prototype.\(tokens[index + 4].text) "
                + "for the scripts after it, but Reqling runs each script on its own; share values through variables instead.")
        }
    }

    /// The globals a level's scripts define without declaring them, `globalThis.name =` and a bare `name =`, by phase.
    static func sharedGlobals(in scripts: ScriptSet) -> [ScriptPhase: Set<String>] {
        var shared: [ScriptPhase: Set<String>] = [:]
        for phase in [ScriptPhase.preRequest, .postResponse] where !scripts[phase].isEmpty {
            let expressions = ScriptExpressions(text: scripts[phase])
            let tokens = expressions.tokens
            var names = Set(expressions.assignedGlobals)
            for index in tokens.indices.dropLast(3) where tokens[index].text == "globalThis" && ScriptExpressions.isDot(tokens[index + 1])
                && tokens[index + 3].isPunctuator("=") {
                names.insert(tokens[index + 2].text)
            }
            shared[phase] = names
        }
        return shared
    }

    /// Every name the collection's scripts set as a variable, which a moved credential's variable mustn't take.
    static func scriptSetNames(in root: PostmanJSON) -> Set<String> {
        var names: Set<String> = []
        func visit(_ node: PostmanJSON) {
            for event in node["event"]?.array ?? [] {
                if let source = event["script"]?["exec"]?.lines {
                    names.formUnion(ScriptAnalyzer.declaredVariables(in: source).map(\.name))
                }
            }
            for child in node["item"]?.array ?? [] {
                visit(child)
            }
        }
        visit(root)
        return names
    }

    // MARK: - Built-in variables

    /// Notes the built-ins a request names that Reqling doesn't generate, such as most of Postman's fake data.
    mutating func noteUnknownDynamicVariables(in spec: HTTPRequestSpec, owner: PostmanImportNote.Owner) {
        var texts = [spec.url] + (spec.queryParameters + spec.headers + spec.body.urlEncoded).flatMap { [$0.key, $0.value] }
        texts += [spec.body.raw.text, spec.body.graphQL.query, spec.body.graphQL.variables] + spec.body.formData.map(\.value)
        switch spec.auth {
        case .basic(let username, let password): texts += [username, password]
        case .bearer(let token): texts.append(token)
        case .apiKey(let name, let value, _): texts += [name, value]
        case .inherit, .none: break
        }
        noteUnknownDynamicVariables(in: texts, owner: owner)
    }

    /// The same for every imported environment's values.
    mutating func noteUnknownDynamicVariables(in targets: PostmanEnvironmentMerge.Targets) {
        for environment in [targets.global, targets.defaultEnvironment] + targets.environments {
            noteUnknownDynamicVariables(in: environment.variables.map(\.value), owner: .environment(environment.name))
        }
    }

    private mutating func noteUnknownDynamicVariables(in texts: [String], owner: PostmanImportNote.Owner) {
        var unknown: [String] = []
        for text in texts where text.contains("{{") {
            for token in TemplateParser.tokens(in: text) where token.kind == .dynamic && !DynamicVariables.isKnown(token.name) {
                if !unknown.contains(token.name) {
                    unknown.append(token.name)
                }
            }
        }
        guard !unknown.isEmpty else {
            return
        }
        let listed = unknown.map { "{{\($0)}}" }
        let names = listed.count > 1 ? listed.dropLast().joined(separator: ", ") + " and " + (listed.last ?? "") : listed.joined()
        note(owner, .variable, "It uses \(names), which Reqling doesn't generate.")
    }
}

/// A global an enclosing level's script defines (`utils = { … }`), and how many scripts below it read it.
struct SharedGlobalUse {
    let owner: PostmanImportNote.Owner
    let phase: ScriptPhase
    let name: String
    var users: Int
}
