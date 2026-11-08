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
        let request = ["method", "url", "headers", "body"]
        XCTAssertEqual(keys("rq.sendRequest({|})"), request)
        XCTAssertEqual(keys("rq.sendRequest({\n  |\n})"), request, "Return moved the closers down a line")
        XCTAssertEqual(keys("rq.sendRequest({\n  url: \"x\",\n  |\n})"), ["method", "headers", "body"], "after `,` and Return")
        XCTAssertEqual(keys("rq.sendRequest({\n  url,\n  he|\n})"), ["headers"], "a shorthand key is written too")
        XCTAssertEqual(keys("const r = rq.sendRequest({\n  url: \"x\",\n  |\n}"), ["method", "headers", "body"], "before a moved-back `}`")
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
        XCTAssertEqual(keys("const pending = rq.sendRequest(\"https://x\")\npending.|"), [], "A promise has none of the response's members")
    }
}
