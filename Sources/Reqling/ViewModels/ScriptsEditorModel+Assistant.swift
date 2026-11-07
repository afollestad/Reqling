import Foundation
import ReqlingKit
import ReqlingScriptProtocol

/// Completion, hover, parameter hints, and problems for the shown script, from `ScriptAnalyzer` and
/// `ScriptSyntaxChecker`: the only place their results become the editor's `Code*` types. Checking waits for typing
/// to pause and runs off the main actor; each result is stamped with the text it checked, which the editor shows only
/// while that is still its text.
extension ScriptsEditorModel: CodeEditorSignatureAssistant {
    static let validationDelay: Duration = .milliseconds(300)

    func completions(in text: String, cursor: Int) -> CodeCompletionList? {
        guard let list = analyzer(text).completions(at: cursor), !list.items.isEmpty else {
            return nil
        }
        let describeVariable = list.isVariableNames ? variableDescriber() : nil
        let items = list.items.enumerated().map { index, item in
            CodeCompletionItem(
                id: index,
                label: item.label,
                kind: Self.kind(item.kind),
                detail: item.detail,
                summary: (item.summary ?? describeVariable?(item.label)).map(Self.plain),
                isDeprecated: false,
                insertText: item.insertText,
                parentheses: item.takesArguments.map { $0 ? .withArguments : .withoutArguments }
            )
        }
        return CodeCompletionList(replacementRange: list.replacementRange, items: items, nameCharacters: list.isVariableNames ? .variableName : .code)
    }

    func hover(in text: String, at offset: Int) -> CodeHoverContent? {
        guard let hover = analyzer(text).hover(at: offset) else {
            return nil
        }
        let summary = [hover.summary, hover.note].compactMap(\.self).map(Self.plain).joined(separator: "\n\n")
        return CodeHoverContent(range: hover.range, signature: hover.signature, summary: summary.isEmpty ? nil : summary, deprecationReason: nil)
    }

    func signatureHelp(in text: String, cursor: Int) -> CodeSignatureHelp? {
        guard let help = analyzer(text).signatureHelp(at: cursor) else {
            return nil
        }
        let summary = [help.summary, help.note].compactMap(\.self).map(Self.plain).joined(separator: "\n\n")
        return CodeSignatureHelp(
            name: help.name,
            parameters: help.parameters.map { parameter in
                CodeSignatureHelp.Parameter(name: parameter.name, label: parameter.label, summary: parameter.summary.map(Self.plain))
            },
            returnType: help.returnType,
            activeParameter: help.activeParameter,
            summary: summary.isEmpty ? nil : summary,
            anchor: help.openParen
        )
    }

    /// A member after `.`, a name as it starts, and a variable name as a string starts: the analyzer offers names
    /// only in the string of an accessor that reads variables.
    func opensCompletion(_ typed: String, before cursor: Int, in text: NSString) -> Bool {
        guard typed.count == 1, let character = typed.first else {
            return false
        }
        if character == "." || character == "\"" || character == "'" {
            return true
        }
        guard CodeTextView.isNameCharacter(character) else {
            return false
        }
        // A digit only continues a name; on its own it is a number.
        guard character.isNumber else {
            return true
        }
        return cursor >= 2 && CodeTextView.isNameCharacter(Character(text.substring(with: NSRange(location: cursor - 2, length: 1))))
    }

    /// Checks the shown script again, after `delay` when typing goes on.
    func validate(after delay: Duration?) {
        validationTask?.cancel()
        validationGeneration += 1
        let generation = validationGeneration
        let source = source
        let context = analysisContext
        let sleep = app.sleep
        validationTask = Task { [weak self] in
            if let delay {
                try? await sleep(delay)
            }
            guard !Task.isCancelled else {
                return
            }
            let items = await Task.detached { Self.problems(in: source, context: context) }.value
            guard let self, generation == validationGeneration else {
                return
            }
            diagnostics = CodeDiagnosticSet(text: source, items: items)
        }
    }

    /// Takes the latest response's JSON for `rq.response.json()`'s keys: an HTTP body, or a gRPC call's last message.
    func loadResponseShape(from exchange: RequestExchange?) async {
        let json: Data? = switch exchange?.outcome {
        case .response(let response)?: response.eventStream == nil ? response.body : nil
        case .grpc(let call)?: call.events.last { $0.direction == .received }.map { Data($0.json.utf8) }
        default: nil
        }
        responseShape = await Task.detached { json.flatMap(ScriptJSONShape.init(json:)) }.value
    }

    /// Where the shown script runs, and what its strings and `json()` can complete with.
    var analysisContext: ScriptAnalysisContext {
        let layers = app.scope(for: projectID).layers
        let declared = app.scriptDeclaredVariables(in: projectID)
        var variables: [ScriptVariableSource: [String]] = [
            .environment: Array((layers.active ?? layers.defaultEnvironment).visibleKeys),
            .defaultEnvironment: Array(layers.defaultEnvironment.visibleKeys),
            .globals: Array(layers.global.visibleKeys)
        ]
        for variable in declared where variable.source != .all {
            variables[variable.source, default: []].append(variable.name)
        }
        for source in variables.keys {
            variables[source] = Array(Set(variables[source] ?? [])).sorted()
        }
        return ScriptAnalysisContext(phase: phase, protocols: protocols, variables: variables, responseShape: responseShape)
    }

    private func analyzer(_ text: String) -> ScriptAnalyzer {
        ScriptAnalyzer(text: text, context: analysisContext)
    }

    /// Where each variable a string argument completes with is defined: the environments that hold it, and the scripts
    /// that set it, never its value. Built only for such a list, as the editor offers one far less often than it checks.
    private func variableDescriber() -> (String) -> String? {
        let layers = app.scope(for: projectID).layers
        let document = app.library.document(projectID)
        var environments: [(name: String, keys: Set<String>)] = []
        if let active = layers.active, let id = app.activeEnvironmentID(for: projectID), let environment = document?.environment(id) {
            environments.append((environment.name, active.visibleKeys))
        }
        if let document {
            environments.append((document.defaultEnvironment.name, layers.defaultEnvironment.visibleKeys))
        }
        environments.append((app.library.globalEnvironment.name, layers.global.visibleKeys))
        var setters: [String: [String]] = [:]
        for variable in app.scriptSetVariables(in: projectID) where !(setters[variable.name] ?? []).contains(variable.setter) {
            setters[variable.name, default: []].append(variable.setter)
        }
        return { name in
            var sentences: [String] = []
            let holders = environments.filter { $0.keys.contains(name) }.map(\.name)
            if !holders.isEmpty {
                sentences.append("In \(Self.list(holders)).")
            }
            if let setters = setters[name], let first = setters.first {
                let others = setters.count - 1
                sentences.append("Set by \(first)\(others > 0 ? " and \(others) more" : "").")
            }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }
    }

    /// "A", "A and B", or "A, B, and C".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }

    /// A request's protocols; a folder's or the project's scripts run for every protocol.
    private var protocols: ScriptProtocols? {
        guard case .request(let id) = owner, let kind = app.library.document(projectID)?.request(id)?.kind.name else {
            return nil
        }
        return ScriptAnalysisContext.protocols(for: kind)
    }

    private nonisolated static func problems(in source: String, context: ScriptAnalysisContext) -> [CodeDiagnostic] {
        var items: [CodeDiagnostic] = []
        if let error = ScriptSyntaxChecker.shared.error(in: source) {
            items.append(CodeDiagnostic(range: error.range, message: error.message, severity: .error))
        }
        items += ScriptAnalyzer(text: source, context: context).diagnostics().map { diagnostic in
            CodeDiagnostic(range: diagnostic.range, message: diagnostic.message, severity: diagnostic.severity == .error ? .error : .warning)
        }
        return items
    }

    /// The catalog's text as the list and the hover card show it, which is plain: they'd show its Markdown backticks.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "")
    }

    private static func kind(_ kind: ScriptSymbolKind) -> CodeSymbolKind {
        switch kind {
        case .namespace: .namespace
        case .property: .property
        case .method: .method
        case .local: .local
        case .variable: .scriptVariable
        case .jsonKey: .jsonKey
        case .keyword: .keyword
        }
    }
}
