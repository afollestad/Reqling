import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Options literals a script passes (`rq.sendRequest({ … })`), and what an awaited request gives.
extension ScriptAnalyzerTests {
    /// What completes at the `|` in `marked`.
    private func completions(at marked: String, phase: ScriptPhase = .preRequest) -> ScriptCompletionList? {
        let cursor = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "")
        let context = ScriptAnalysisContext(phase: phase, protocols: ScriptAnalysisContext.protocols(for: .http))
        return ScriptAnalyzer(text: text, context: context).completions(at: cursor)
    }

    private func keys(_ marked: String) -> [String]? {
        completions(at: marked)?.items.map(\.label)
    }

    /// The editor pairs `({` with `})` and indents on Return, so the cursor lands in each of these as keys are typed.
    func testAnOptionsLiteralCompletesItsKeysWhereverPairsAndIndentationLeaveTheCursor() throws {
        let request = ["method", "url", "headers", "body", "timeout"]
        XCTAssertEqual(keys("rq.sendRequest({|})"), request)
        XCTAssertEqual(keys("rq.sendRequest({\n  |\n})"), request, "Return moved the closers down a line")
        XCTAssertEqual(keys("rq.sendRequest({\n  url: \"x\",\n  |\n})"), ["method", "headers", "body", "timeout"], "after `,` and Return")
        XCTAssertEqual(keys("rq.sendRequest({\n  url,\n  he|\n})"), ["headers"], "a shorthand key is written too")
        XCTAssertEqual(keys("const r = rq.sendRequest({\n  url: \"x\",\n  |\n}"), ["method", "headers", "body", "timeout"], "before a moved-back `}`")
        XCTAssertEqual(keys("rq.runRequest(\"Login\", {|})"), ["variables"])
        XCTAssertEqual(keys("rq.cookies.set(\"a\", \"b\", {|})"), ["path", "domain", "expires", "secure", "httpOnly", "sameSite"])
        XCTAssertEqual(keys("rq.environment.set(\"k\", \"v\", { se|})"), ["secret"])

        let typed = try XCTUnwrap(completions(at: "rq.sendRequest({ me|})"))
        XCTAssertEqual(typed.items.map(\.insertText), ["method: "])
        XCTAssertEqual(typed.replacementRange, NSRange(location: 17, length: 2))
        XCTAssertEqual(completions(at: "rq.sendRequest({ me|: \"POST\" })")?.items.map(\.insertText), ["method"], "renaming keeps its colon")
    }

    func testOnlyALiteralPassedWholeWhereAParameterTakesOptionsCompletesKeys() {
        XCTAssertFalse(keys("rq.sendRequest({ headers: { |} })")?.contains("method") ?? false, "a nested literal is the header's")
        XCTAssertFalse(keys("rq.sendRequest(\"https://x\", {|})")?.contains("method") ?? false, "a second argument takes nothing")
        XCTAssertFalse(keys("rq.sendRequest([{|}])")?.contains("method") ?? false, "inside an array")
        XCTAssertTrue(keys("if (true) {|}")?.contains("rq") ?? false, "a block starts a name as before")
    }

    func testAKeysStringValueCompletesTheValuesItsPropertyNames() throws {
        let methods = try XCTUnwrap(completions(at: "rq.sendRequest({ method: \"|\" })"))
        XCTAssertEqual(methods.items.map(\.label), ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
        XCTAssertEqual(methods.items.first?.kind, .value)
        XCTAssertEqual(methods.replacementRange, NSRange(location: 26, length: 0), "the string's contents")
        XCTAssertEqual(completions(at: "rq.sendRequest({ method: \"p|\" })")?.items.map(\.label), ["POST", "PUT", "PATCH"])
        XCTAssertEqual(completions(at: "rq.cookies.set(\"a\", \"b\", { sameSite: \"|\" })")?.items.map(\.label), ["lax", "strict", "none"])
        XCTAssertNil(completions(at: "rq.sendRequest({ url: \"|\" })"), "a URL names no values")
    }

    func testHoverDescribesAnOptionsKey() throws {
        let text = "rq.sendRequest({ method: \"GET\" })"
        let hover = try XCTUnwrap(ScriptAnalyzer(text: text, context: ScriptAnalysisContext(phase: .preRequest, protocols: nil)).hover(at: 18))

        XCTAssertEqual(hover.signature, "OutgoingRequest.method: string")
        XCTAssertEqual(hover.summary, "The HTTP method; `GET` when left out.")
        XCTAssertEqual(hover.range, NSRange(location: 17, length: 6))
    }

    func testAnAwaitedRequestGivesItsResponseWhileTheRequestItselfIsAPromise() throws {
        let awaited = try XCTUnwrap(keys("const res = await rq.sendRequest(\"https://x\")\nres.|"))
        let destructured = try XCTUnwrap(keys("const { headers } = await rq.runRequest(\"Login\")\nheaders.|"))

        XCTAssertTrue(awaited.contains("code") && awaited.contains("json"), "\(awaited)")
        XCTAssertTrue(destructured.contains("get"), "\(destructured)")
        XCTAssertEqual(keys("const pending = rq.sendRequest(\"https://x\")\npending.|"), ["then", "catch", "finally"],
                       "A promise has its own members, not the response's")
    }

    func testThenGivesItsCallbackWhatThePromiseSettlesWith() throws {
        let then = try XCTUnwrap(keys("rq.sendRequest(\"https://x\").then((res) => res.|)"))
        let chained = try XCTUnwrap(keys("rq.runRequest(\"Login\").then(res => res.|"))
        let hover = try XCTUnwrap(ScriptAnalyzer(
            text: "rq.sendRequest(\"https://x\").then(r => r)",
            context: ScriptAnalysisContext(phase: .preRequest, protocols: nil)
        ).hover(at: 29))

        XCTAssertTrue(then.contains("code") && then.contains("json"), "\(then)")
        XCTAssertTrue(chained.contains("status"), "\(chained)")
        XCTAssertEqual(hover.signature,
                       "Promise.then(onFulfilled: (value: IncomingResponse) => void, onRejected?: (error: any) => void): Promise<any>")
        XCTAssertEqual(keys("rq.sendRequest(\"https://x\").catch((error) => error.|)") ?? [], [], "an error is untyped")
    }

    /// The latest response's keys describe this request's response alone, never one a script's request got.
    func testOnlyThisRequestsResponseCompletesItsJSONKeys() throws {
        let shape = try XCTUnwrap(ScriptJSONShape(json: Data(#"{"user": {"id": 1}}"#.utf8)))
        let context = ScriptAnalysisContext(phase: .postResponse, protocols: [.http], responseShape: shape)
        func keys(_ text: String) -> [String] {
            ScriptAnalyzer(text: text, context: context).completions(at: (text as NSString).length)?.items.map(\.label) ?? []
        }

        XCTAssertEqual(keys("pm.response.json()."), ["user"])
        XCTAssertEqual(keys("pm.sendRequest('x', (err, res) => res.json()."), [])
        XCTAssertEqual(keys("const res = await rq.sendRequest('x')\nres.json()."), [])
    }

    /// A cookie's `sameSite` takes only its three values, in any case; an HTTP method's are suggestions, and a value
    /// built at run time is the runtime's to check.
    func testAValueOutsideAPropertysOnlyChoicesIsWarnedAbout() throws {
        let context = ScriptAnalysisContext(phase: .preRequest, protocols: ScriptAnalysisContext.protocols(for: .http))
        let text = [
            #"rq.cookies.set("a", "b", { sameSite: "laxx" })"#,
            #"rq.cookies.set("a", "b", { sameSite: "Strict", secure: true })"#,
            #"rq.cookies.set("a", "b", { sameSite: "l" + "ax" })"#,
            #"rq.sendRequest({ url: "x", method: "PURGE" })"#
        ].joined(separator: "\n")
        let warnings = ScriptAnalyzer(text: text, context: context).diagnostics()

        XCTAssertEqual(warnings.map(\.message), ["rq.cookies.set's sameSite is lax, strict, or none, not “laxx”."])
        XCTAssertEqual(warnings.first?.range, (text as NSString).range(of: #""laxx""#))
    }

    func testAKeyAnOptionsTypeLacksIsWarnedAbout() {
        let context = ScriptAnalysisContext(phase: .preRequest, protocols: ScriptAnalysisContext.protocols(for: .http))
        let text = "rq.sendRequest({ url: \"x\", hedaers: {}, \"tiemout\": 1, headers: { anything: 1 } })\n"
            + "rq.cookies.set(\"a\", \"b\", { secure: true, ttl: 1 })"
        let warnings = ScriptAnalyzer(text: text, context: context).diagnostics()

        XCTAssertEqual(warnings.map(\.message), [
            "rq.sendRequest's options have no “hedaers”.",
            "rq.sendRequest's options have no “tiemout”.",
            "rq.cookies.set's options have no “ttl”."
        ])
        XCTAssertEqual(warnings.first?.range, NSRange(location: 27, length: 7))
        XCTAssertTrue(ScriptAnalyzer(text: "if (x) { nope: 1 }\nfoo({ nope: 1 })", context: context).diagnostics().isEmpty,
                      "a block or a call the catalog doesn't know has no options")
    }
}
