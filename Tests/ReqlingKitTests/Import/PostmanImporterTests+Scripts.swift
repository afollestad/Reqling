import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Postman's scripts as each level's own, with the problems a script has in Reqling noted where it is.
extension PostmanImporterTests {
    func testScriptsBelongToTheirLevelAndTheirProblemsAreNoted() throws {
        let plan = try petstore()
        guard case .request(let login)? = node(plan, "Auth", "Login") else {
            return XCTFail("Login is a request")
        }

        XCTAssertEqual(plan.scripts.preRequest, "utils = { stamp: () => Date.now() }")
        XCTAssertEqual(plan.scripts.postResponse, "pm.test(\"is ok\", () => pm.response.to.be.ok)")
        XCTAssertTrue(login.scripts.postResponse.hasPrefix("const body = pm.response.json();\npm.environment.set"))
        XCTAssertTrue(plan.hasScripts)
        let loginNotes = plan.notes.filter { $0.owner == .node(["Auth", "Login"]) }
        XCTAssertEqual(loginNotes.map(\.topic), [.script(.postResponse, line: 3), .script(.postResponse, line: 3)])
        XCTAssertEqual(loginNotes.first?.message,
                       "postman.setEnvironmentVariable is from Postman's old script API, which Reqling doesn't have; use pm.environment.set.")
    }

    /// Postman's sandbox lets a collection's script define a global for the scripts below it; Reqling's doesn't.
    func testAGlobalAnEnclosingScriptDefinesIsNotedOnce() throws {
        let plan = try self.plan(items: """
        [{"name": "Folder", "event": [{"listen": "prerequest", "script": {"exec": "Object.prototype.sign = () => 1"}}],
          "item": [{"name": "A", "event": [{"listen": "prerequest", "script": {"exec": "utils.stamp()"}}], "request": "https://x"},
                   {"name": "B", "event": [{"listen": "test", "script": {"exec": ["const utils = {}", "utils.stamp()"]}}], "request": "https://x"},
                   {"name": "C", "event": [{"listen": "test", "script": {"exec": "pm.test('x', () => utils.stamp())"}}], "request": "https://x"}]}]
        """, extra: #""event": [{"listen": "prerequest", "script": {"exec": "utils = { stamp: () => Date.now() }"}}]"#)

        XCTAssertEqual(messages(plan), [
            "Its pre-request script defines utils and 2 scripts after it read it, but Reqling runs each script on its own; "
                + "share it through a variable, or define it where it's read."
        ], "B declares its own")
        XCTAssertEqual(messages(plan, "Folder"), [
            "Its pre-request script adds Object.prototype.sign for the scripts after it, but Reqling runs each script on its own; "
                + "share values through variables instead."
        ])
    }

    func testTurnedOffAndSplitScriptsAreHandledAsPostmanRunsThem() throws {
        let plan = try self.plan(items: """
        [{"name": "R", "request": "https://x", "event": [
          {"listen": "prerequest", "script": {"exec": ["const a = 1"]}},
          {"listen": "prerequest", "script": {"exec": ["const b = 2"]}},
          {"listen": "test", "disabled": true, "script": {"exec": ["pm.test('off')"]}}]},
         {"name": "Plain", "request": "https://x"}]
        """)
        guard case .request(let request)? = node(plan, "R") else {
            return XCTFail("R is a request")
        }

        XCTAssertEqual(request.scripts.preRequest, "const a = 1\n\nconst b = 2")
        XCTAssertEqual(request.scripts.postResponse, "")
        XCTAssertEqual(messages(plan, "R"), ["Its post-response script was turned off in Postman, so it isn't imported."])
        XCTAssertFalse(try self.plan(items: #"[{"name": "Plain", "request": "https://x"}]"#).hasScripts)
    }
}
