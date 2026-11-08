import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// What scripts brought from Postman use that Reqling's runtime lacks: Postman's old API, libraries Reqling doesn't
/// bundle, and keys `pm.sendRequest` refuses.
extension ScriptAnalyzerTests {
    private func legacyWarnings(_ text: String, phase: ScriptPhase = .postResponse) -> [String] {
        let context = ScriptAnalysisContext(phase: phase, protocols: ScriptAnalysisContext.protocols(for: .http))
        return ScriptAnalyzer(text: text, context: context).diagnostics().map(\.message)
    }

    func testPostmansOldAPIWarnsWithWhatToUseInstead() {
        XCTAssertEqual(legacyWarnings("postman.setEnvironmentVariable('token', responseBody)"), [
            "postman.setEnvironmentVariable is from Postman's old script API, which Reqling doesn't have; use pm.environment.set.",
            "responseBody is from Postman's old script API, which Reqling doesn't have; use pm.response.text()."
        ])
        XCTAssertEqual(legacyWarnings("tests['is ok'] = responseCode.code === 200"), [
            "tests is from Postman's old script API, which Reqling doesn't have; use pm.test.",
            "responseCode is from Postman's old script API, which Reqling doesn't have; use pm.response.code."
        ])
        XCTAssertEqual(legacyWarnings("postman.somethingNew()"), [
            "postman.somethingNew is from Postman's old script API, which Reqling doesn't have; use pm."
        ])
        XCTAssertEqual(legacyWarnings("const page = cheerio.load(pm.response.text())"), [
            "cheerio is a library Postman's scripts have and Reqling's don't."
        ])
    }

    /// A name the script defines is its own, and a member, key, or method that shares a legacy name isn't one.
    func testOnlyAnUndefinedLegacyNameWarns() {
        let script = """
        const data = pm.response.json()
        function tests(request) { return request }
        rq.test("x", ({ responseBody }) => responseBody)
        iteration = 1
        const body = { environment: 1, globals() { return 2 } }
        if (typeof xml2Json === "undefined") { console.log(data.tests, body.environment) }
        // responseCode in a comment, and "responseTime" in a string
        """

        XCTAssertEqual(legacyWarnings(script), [])
        XCTAssertEqual(legacyWarnings("const payload = { data }"), [
            "data is from Postman's old script API, which Reqling doesn't have; use pm.iterationData."
        ], "a shorthand key reads the variable")
    }

    func testRequireWarnsOfALibraryReqlingDoesntBundle() {
        XCTAssertEqual(legacyWarnings("const moment = require('moment')"), ["require's name is crypto-js or lodash, not “moment”."])
        XCTAssertEqual(legacyWarnings("require('Lodash')"), ["require's name is crypto-js or lodash, not “Lodash”."],
                       "require takes a library's name exactly as written")
        XCTAssertEqual(legacyWarnings("const _ = require('lodash')\nconst CryptoJS = require(\"crypto-js\")\nrequire(name)"), [])
    }

    func testRequireCompletesTheLibrariesItLoads() {
        let text = "require(\"cr"
        let context = ScriptAnalysisContext(phase: .preRequest, protocols: ScriptAnalysisContext.protocols(for: .http))
        let completions = ScriptAnalyzer(text: text, context: context).completions(at: (text as NSString).length)

        XCTAssertEqual(completions?.items.map(\.label), ["crypto-js"])
        XCTAssertEqual(completions?.isVariableNames, false)
    }

    func testPMSendRequestWarnsOfAKeyItRefuses() {
        XCTAssertEqual(legacyWarnings("pm.sendRequest({ url: 'https://x', auth: { type: 'bearer' } })"), [
            "pm.sendRequest's auth isn't supported in Reqling: a script's request goes without auth, so set its header instead."
        ])
        XCTAssertEqual(legacyWarnings("pm.sendRequest({ url: 'https://x', timeout: 5 })"), ["pm.sendRequest's options have no “timeout”."])
        XCTAssertEqual(legacyWarnings("pm.sendRequest({ url: 'https://x', method: 'POST', header: [], body: {} }, (error, res) => {})"), [])

        let text = "pm.sendRequest({ "
        let context = ScriptAnalysisContext(phase: .preRequest, protocols: ScriptAnalysisContext.protocols(for: .http))
        let offered = ScriptAnalyzer(text: text, context: context).completions(at: (text as NSString).length)?.items.map(\.label) ?? []
        XCTAssertFalse(offered.contains("header"), "pm's keys are never offered")
    }
}
