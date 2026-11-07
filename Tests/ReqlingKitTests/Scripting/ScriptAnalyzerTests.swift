import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Completion, hover, warnings, and declared variables, resolved through the catalog the runtime implements.
final class ScriptAnalyzerTests: XCTestCase {
    private static let http = ScriptAnalysisContext.protocols(for: .http)

    private func labels(
        _ text: String,
        phase: ScriptPhase = .postResponse,
        protocols: ScriptProtocols? = http,
        variables: [ScriptVariableSource: [String]] = [:],
        shape: ScriptJSONShape? = nil
    ) -> [String]? {
        let context = ScriptAnalysisContext(phase: phase, protocols: protocols, variables: variables, responseShape: shape)
        let utf16 = (text as NSString).length
        return ScriptAnalyzer(text: text, context: context).completions(at: utf16)?.items.map(\.label)
    }

    private func warnings(_ text: String, phase: ScriptPhase = .preRequest, protocols: ScriptProtocols? = http) -> [String] {
        ScriptAnalyzer(text: text, context: ScriptAnalysisContext(phase: phase, protocols: protocols)).diagnostics().map(\.message)
    }

    func testMembersAreThoseOfThePhaseAndProtocol() throws {
        let post = try XCTUnwrap(labels("rq."))
        let pre = try XCTUnwrap(labels("rq.", phase: .preRequest))
        let grpcRequest = try XCTUnwrap(labels("rq.request.", protocols: [.grpc]))
        let folderRequest = try XCTUnwrap(labels("rq.request.", protocols: nil))

        XCTAssertTrue(post.contains("response"))
        XCTAssertFalse(pre.contains("response"), "The response exists only after it arrives")
        XCTAssertTrue(grpcRequest.contains("metadata"))
        XCTAssertFalse(grpcRequest.contains("method"))
        XCTAssertTrue(folderRequest.contains("metadata") && folderRequest.contains("method"), "A folder's script runs for every protocol")
        XCTAssertEqual(labels("rq.request.he"), ["headers"])
    }

    func testAliasesDestructuringAndCallsResolve() {
        XCTAssertEqual(labels("const r = rq.request\nr.he"), ["headers"])
        XCTAssertEqual(labels("const { headers: h } = rq.request\nh.ups", phase: .preRequest), ["upsert"], "Rows change only before sending")
        XCTAssertEqual(labels("rq.expect(1).to"), ["to"])
        XCTAssertEqual(labels("rq.test.sk"), ["skip"], "A function's own properties")
    }

    func testResponseJSONKeysComeFromTheLatestResponse() throws {
        let shape = try XCTUnwrap(ScriptJSONShape(json: Data(#"{"data":{"users":[{"id":1},{"id":2,"name":"Ada"}]},"next":null}"#.utf8)))

        XCTAssertEqual(labels("rq.response.json().", shape: shape), ["data", "next"])
        XCTAssertEqual(labels("rq.response.json().data.users[0].", shape: shape), ["id", "name"], "Items of one array merge")
        XCTAssertEqual(labels("const body = rq.response.json()\nbody.data.u", shape: shape), ["users"])
    }

    func testAStringArgumentCompletesTheVariablesItsAccessorReads() throws {
        let variables: [ScriptVariableSource: [String]] = [.environment: ["token", "tenant"], .globals: ["region"]]
        let context = ScriptAnalysisContext(phase: .preRequest, protocols: Self.http, variables: variables)
        let text = #"rq.environment.get("te")"#
        let list = try XCTUnwrap(ScriptAnalyzer(text: text, context: context).completions(at: 22))

        XCTAssertEqual(list.items.map(\.label), ["token", "tenant"].filter { $0.hasPrefix("te") })
        XCTAssertTrue(list.isVariableNames)
        XCTAssertEqual(list.replacementRange, NSRange(location: 20, length: 2), "The whole name in the quotes")
        XCTAssertEqual(labels(#"rq.variables.get(""#, variables: variables), ["region", "tenant", "token"], "Every layer")
        XCTAssertNil(labels(#"console.log("te"#, variables: variables), "Not every string names a variable")
        XCTAssertNil(labels(#"rq.environment.get("token""#, variables: variables), "Nothing right after a closing quote")
    }

    func testNamesOfferGlobalsAndLocalsButNeverPMOrAnythingInAComment() throws {
        let names = try XCTUnwrap(labels("const total = 1\n"))

        XCTAssertEqual(names.first, "total")
        XCTAssertTrue(names.contains("rq") && names.contains("console") && names.contains("await"))
        XCTAssertFalse(names.contains("pm"))
        XCTAssertNil(labels("// rq."))
        XCTAssertEqual(labels("pm.").map(\.isEmpty), true, "pm is for scripts from Postman, not for writing")
    }

    func testHoverDescribesMembersAndMapsPostmanNames() throws {
        let text = "rq.request.headers\npm.environment"
        let analyzer = ScriptAnalyzer(text: text, context: ScriptAnalysisContext(phase: .preRequest))

        let headers = try XCTUnwrap(analyzer.hover(at: 13))
        let environment = try XCTUnwrap(analyzer.hover(at: 25))

        XCTAssertEqual(headers.signature, "Request.headers: Rows")
        XCTAssertEqual(headers.range, NSRange(location: 11, length: 7))
        XCTAssertEqual(environment.note, "For scripts from Postman. Reqling's own is `rq.environment`.")
    }

    func testWarningsNameWhatDoesntWorkWhereTheScriptRuns() {
        XCTAssertEqual(warnings("rq.response.code"), ["rq.response works only in post-response scripts."])
        XCTAssertEqual(warnings("rq.request.foo"), ["rq.request has no “foo”."])
        XCTAssertEqual(warnings("rq.request.metadata"), ["rq.request.metadata applies only to gRPC requests."])
        XCTAssertEqual(warnings("pm.sendRequest()"), ["pm.sendRequest isn't supported in Reqling: scripts can't make network calls."])
        XCTAssertEqual(warnings("const r = rq.request\nr.nope"), ["rq.request has no “nope”."])
        XCTAssertEqual(warnings("rq.expect(1).to.be.true\n_.whatever(1)\nlocal.thing"), [], "Open types and locals are never warned about")
    }

    func testAParameterHidesAGlobalOnlyWithinItsFunction() {
        let script = """
        rq.test("x", (rq) => rq.nope)
        [1].map(_ => _.id)
        function f(console, { request: rq }) { console.nope; rq.nope }
        try {} catch (rq) { rq.nope }
        const checks = { verify(rq) { rq.nope } }
        rq.request.foo
        """

        XCTAssertEqual(warnings(script), ["rq.request has no “foo”."], "Outside its function, a parameter's name means the global again")
        XCTAssertEqual(labels("[1].map(_ => _.id)\n_.ge"), ["get"], "Lodash again after the arrow")
        XCTAssertEqual(labels("[1].map((item) => it"), ["item"])
    }

    func testVariablesSetByLiteralNameAreDeclared() {
        let source = """
        rq.environment.set("token", 1)
        pm.collectionVariables.set('base', 2)
        rq.variables.set("local", 3)
        rq.environment.set(name, 4)
        rq.environment.get("read")
        """

        let declared = ScriptAnalyzer.declaredVariables(in: source)

        XCTAssertEqual(declared, [
            ScriptDeclaredVariable(name: "token", source: .environment),
            ScriptDeclaredVariable(name: "base", source: .defaultEnvironment),
            ScriptDeclaredVariable(name: "local", source: .all)
        ])
    }

    func testTheSyntaxCheckerParsesAsTheRunnerWraps() throws {
        let checker = ScriptSyntaxChecker.shared

        XCTAssertNil(checker.error(in: "const a = await Promise.resolve(1)\nif (a) return"), "Top-level await and return parse")
        let unclosed = try XCTUnwrap(checker.error(in: "rq.test(\"x\", () => {\n  rq.expect(1)\n"))
        let misplaced = try XCTUnwrap(checker.error(in: "const a = 1\nconst = 2"))

        XCTAssertTrue(unclosed.message.hasPrefix("SyntaxError"), unclosed.message)
        XCTAssertEqual(misplaced.line, 2)
        XCTAssertEqual(misplaced.range, NSRange(location: 12, length: 9), "Line 2 of the script, not of the wrapped text")
    }
}
