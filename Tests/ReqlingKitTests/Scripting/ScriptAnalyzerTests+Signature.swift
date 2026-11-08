import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Parameter hints: the method a call names, and the argument the cursor (`|`) is in.
extension ScriptAnalyzerTests {
    private func hint(_ marked: String, phase: ScriptPhase = .postResponse) -> (signature: String, active: String?)? {
        let cursor = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        let context = ScriptAnalysisContext(phase: phase, protocols: ScriptAnalysisContext.protocols(for: .http))
        guard let help = ScriptAnalyzer(text: text, context: context).signatureHelp(at: cursor) else {
            return nil
        }
        let signature = "\(help.name)(\(help.parameters.map(\.label).joined(separator: ", ")))" + (help.returnType.map { ": \($0)" } ?? "")
        return (signature, help.activeParameter.map { help.parameters[$0].name })
    }

    func testTheArgumentAtTheCursorIsActive() throws {
        let opened = try XCTUnwrap(hint("rq.cookies.set(|"))
        XCTAssertEqual(opened.signature, "RequestCookies.set(name: string, value: any, options?: CookieOptions): void")
        XCTAssertEqual(opened.active, "name")
        XCTAssertEqual(hint(#"rq.cookies.set("a", |"#)?.active, "value")
        XCTAssertEqual(hint(#"rq.cookies.set("a", 1, |)"#)?.active, "options")
        XCTAssertEqual(hint(#"rq.environment.get("to|ken")"#)?.active, "name", "inside a string argument")
        XCTAssertEqual(hint("rq.cookies.get(|)")?.active, "name", "before the call's own `)`")
        XCTAssertNil(hint(#"rq.cookies.get("a", |"#)?.active, "past the last parameter")
        XCTAssertEqual(hint(#"rq.cookies.get("a", |"#)?.signature, "RequestCookies.get(name: string): string | null")
    }

    func testTheInnermostCallWinsAndAClosedOneIsLeft() {
        XCTAssertEqual(hint(#"rq.expect(rq.cookies.get(|"#)?.signature, "RequestCookies.get(name: string): string | null")
        XCTAssertEqual(hint(#"rq.expect(rq.cookies.get("a"), |"#)?.active, "message")
        XCTAssertNil(hint(#"rq.cookies.get("a")|"#))
        XCTAssertNil(hint("rq.expect(unknown(1, |"), "an unknown call never shows the call around it")
    }

    func testArgumentsBuiltFromLiteralsAndGroupsKeepTheirCall() {
        XCTAssertEqual(hint(#"rq.cookies.set("a", 1, { path: "/", se|"#)?.active, "options", "an object literal")
        XCTAssertEqual(hint("rq.sendRequest({\n  url: \"x\",\n  |\n})")?.active, "request", "lines down an options literal")
        XCTAssertEqual(hint("rq.expect(1).to.be.oneOf([1, 2|")?.active, "values", "an array")
        XCTAssertEqual(hint(#"rq.environment.get(`${rq.info.environment}-|`)"#)?.active, "name", "template text")
        XCTAssertEqual(hint(#"rq.test("works", (a, b|"#)?.active, "callback", "an arrow function's parameters")
        XCTAssertEqual(hint("console.log((1 + 2), |")?.active, "values")
    }

    func testABlockOrAControlStatementEndsTheSearch() {
        XCTAssertNil(hint(#"rq.test("works", () => { |"#))
        XCTAssertNil(hint(#"rq.test("works", () => { if (|"#))
        XCTAssertNil(hint("// rq.cookies.get(|"), "a comment")
    }

    func testARestParameterTakesEveryArgumentFromItsPlace() {
        XCTAssertEqual(hint(#"console.log("a", 1, true, |"#)?.signature, "Console.log(...values: any[]): void")
        XCTAssertEqual(hint(#"console.log("a", 1, true, |"#)?.active, "values")
        XCTAssertEqual(hint("Math.max(1, 2, |")?.active, "values")
    }

    func testTheScriptsOwnFunctionsShowTheirParametersAsWritten() {
        XCTAssertEqual(hint("function sign(key, data) {}\nsign(|")?.signature, "sign(key, data)")
        XCTAssertEqual(hint("const add = (a, b = 1) => a + b\nadd(1, |")?.active, "b")
        XCTAssertEqual(hint("const add = (a, b = 1) => a + b\nadd(|")?.signature, "add(a, b = 1)")
        XCTAssertEqual(hint("const twice = x => x * 2\ntwice(|")?.signature, "twice(x)")
        XCTAssertEqual(hint("const load = async function (url, ...rest) {}\nload(1, 2, 3, |")?.active, "rest", "a rest parameter")
        XCTAssertEqual(hint("function f({ id, name }, done) {}\nf(|")?.signature, "f({ id, name }, done)")
        XCTAssertEqual(hint("go(|)\nfunction go(where) {}")?.signature, "go(where)", "a declaration is hoisted")
        XCTAssertNil(hint("later(|)\nconst later = (x) => x"), "a binding isn't, before it's declared")
        XCTAssertEqual(hint("function btoa(value) {}\nbtoa(|")?.signature, "btoa(value)", "the script's own wins over a global")
        XCTAssertNil(hint("const x = 1\nx(|"))
    }

    func testADocCommentDescribesTheScriptsOwnFunction() throws {
        let text = """
        /**
         * Signs a payload with the key.
         * @param {string} key - The secret.
         * @param {object} [payload] What to sign.
         * @returns {string}
         */
        function sign(key, payload) {}
        sign(
        """
        let context = ScriptAnalysisContext(phase: .preRequest)
        let help = try XCTUnwrap(ScriptAnalyzer(text: text, context: context).signatureHelp(at: (text as NSString).length))
        XCTAssertEqual(help.summary, "Signs a payload with the key.")
        XCTAssertEqual(help.parameters.map(\.label), ["key: string", "payload: object"])
        XCTAssertEqual(help.parameters.map(\.summary), ["The secret.", "What to sign."])
        XCTAssertNil(help.returnType)

        let plain = "// Not a doc comment.\nfunction f(a) {}\nf("
        let undocumented = try XCTUnwrap(ScriptAnalyzer(text: plain, context: context).signatureHelp(at: (plain as NSString).length))
        XCTAssertEqual(undocumented.summary, "Declared in this script.")
    }

    /// So accepting a method adds `()`, with the cursor between them only when there is something to type there.
    func testMethodCompletionsSayWhetherTheyTakeArguments() throws {
        let context = ScriptAnalysisContext(phase: .postResponse, protocols: ScriptAnalysisContext.protocols(for: .http))
        let items = try XCTUnwrap(ScriptAnalyzer(text: "rq.cookies.", context: context).completions(at: 11)?.items)
        let takesArguments = Dictionary(items.map { ($0.label, $0.takesArguments) }) { first, _ in first }

        XCTAssertEqual(takesArguments["get"], true)
        XCTAssertEqual(takesArguments["toObject"], false)
        XCTAssertEqual(takesArguments["for"], true)
        let globals = try XCTUnwrap(ScriptAnalyzer(text: "", context: context).completions(at: 0)?.items)
        XCTAssertEqual(globals.first { $0.label == "rq" }?.takesArguments, .some(nil), "a property isn't called")
    }

    func testGlobalsAliasesAndPostmanNamesResolve() throws {
        XCTAssertEqual(hint("btoa(|")?.signature, "btoa(text: string): string")
        XCTAssertEqual(hint("const c = rq.cookies\nc.has(|")?.signature, "RequestCookies.has(name: string): boolean")
        XCTAssertEqual(hint("const { cookies } = rq\ncookies.remove(|")?.active, "name")
        XCTAssertEqual(hint(#"rq.test.skip("later", |"#)?.active, "callback")

        let context = ScriptAnalysisContext(phase: .preRequest)
        let postman = try XCTUnwrap(ScriptAnalyzer(text: "pm.environment.get(", context: context).signatureHelp(at: 19))
        XCTAssertEqual(postman.name, "PostmanEnvironment.get")
        XCTAssertEqual(postman.note, "For scripts from Postman. Reqling's own is `rq.environment.get`.")
        XCTAssertEqual(postman.openParen, 18)
    }
}
