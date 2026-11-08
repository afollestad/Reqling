import Foundation

/// Warnings for names from Postman's old script API (`postman.setEnvironmentVariable`, `tests["…"]`, `responseBody`)
/// and for libraries Postman's sandbox has as globals. Scripts brought from Postman still use them, and each throws a
/// `ReferenceError` in Reqling, so the warning names the `pm` member to use instead.
///
/// These names are deliberately absent from `ScriptAPICatalog`, which lists exactly what the runtime has
/// (`ScriptRuntimeConformanceTests` checks both ways), so they're listed here instead. Only a name the script doesn't
/// define anywhere (`ScriptExpressions.declaredNames`) warns: one it declares is its own.
extension ScriptAnalyzer {
    func postmanLegacyDiagnostics() -> [ScriptDiagnostic] {
        let tokens = expressions.tokens
        var found: [ScriptDiagnostic] = []
        for index in tokens.indices where tokens[index].kind == .identifier {
            let name = tokens[index].text
            guard let advice = Self.legacyGlobals[name], !expressions.declaredNames.contains(name), isReference(at: index) else {
                continue
            }
            if name == "postman", index + 2 < tokens.count, ScriptExpressions.isDot(tokens[index + 1]),
               ScriptExpressions.isMemberName(tokens[index + 2]) {
                let member = tokens[index + 2].text
                let range = NSUnionRange(tokens[index].range, tokens[index + 2].range)
                let replacement = Self.legacyPostmanMembers[member] ?? advice
                found.append(ScriptDiagnostic(range: range, message: Self.message("postman.\(member)", replacement), severity: .warning))
            } else {
                found.append(ScriptDiagnostic(range: tokens[index].range, message: Self.message(name, advice), severity: .warning))
            }
        }
        return found
    }

    /// Whether the identifier at `index` reads a variable, rather than naming a member, an object key, or a method a
    /// class or object literal defines; `typeof` reads one without throwing.
    private func isReference(at index: Int) -> Bool {
        let tokens = expressions.tokens
        if index >= 1 {
            let previous = tokens[index - 1]
            if ScriptExpressions.isDot(previous) || (previous.kind == .keyword && previous.text == "typeof") {
                return false
            }
            let isKeyPosition = previous.isPunctuator("{") || previous.isPunctuator(",")
            if isKeyPosition, index + 1 < tokens.count, tokens[index + 1].isPunctuator(":") {
                return false
            }
        }
        // `name(…) {` defines a method; a call is never followed by a block.
        if index + 1 < tokens.count, tokens[index + 1].isPunctuator("("),
           let close = expressions.closer(of: index + 1, open: "(", close: ")"),
           close + 1 < tokens.count, tokens[close + 1].isPunctuator("{") {
            return false
        }
        return true
    }

    private static func message(_ name: String, _ advice: Advice) -> String {
        switch advice {
        case .use(let replacement):
            "\(name) is from Postman's old script API, which Reqling doesn't have; use \(replacement)."
        case .library:
            "\(name) is a library Postman's scripts have and Reqling's don't."
        }
    }

    private enum Advice {
        /// What to write instead, as a phrase: `pm.response.text()`, or a sentence's end for one with no single equivalent.
        case use(String)
        /// A library Postman's sandbox has as a global.
        case library
    }

    /// Postman's old globals, each with what to use instead.
    private static let legacyGlobals: [String: Advice] = [
        "postman": .use("pm"),
        "tests": .use("pm.test"),
        "responseBody": .use("pm.response.text()"),
        "responseCode": .use("pm.response.code"),
        "responseHeaders": .use("pm.response.headers"),
        "responseTime": .use("pm.response.responseTime"),
        "responseCookies": .use("pm.cookies"),
        "request": .use("pm.request"),
        "environment": .use("pm.environment"),
        "globals": .use("pm.globals"),
        "data": .use("pm.iterationData"),
        "iteration": .use("pm.info.iteration"),
        "xml2Json": .library,
        "tv4": .library,
        "cheerio": .library,
        "Buffer": .library
    ]

    /// The old `postman` object's members, each with its `pm` equivalent.
    private static let legacyPostmanMembers: [String: Advice] = [
        "setEnvironmentVariable": .use("pm.environment.set"),
        "getEnvironmentVariable": .use("pm.environment.get"),
        "clearEnvironmentVariable": .use("pm.environment.unset"),
        "clearEnvironmentVariables": .use("pm.environment.unset for each key"),
        "setGlobalVariable": .use("pm.globals.set"),
        "getGlobalVariable": .use("pm.globals.get"),
        "clearGlobalVariable": .use("pm.globals.unset"),
        "clearGlobalVariables": .use("pm.globals.unset for each key"),
        "setNextRequest": .use("pm.execution.setNextRequest"),
        "getResponseHeader": .use("pm.response.headers.get"),
        "getResponseCookie": .use("pm.cookies.get")
    ]
}
