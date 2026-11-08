import Foundation
import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

@testable import Reqling

/// The script editor's completion and problems, and the `{{names}}` scripts set counting as defined.
@MainActor
extension ScriptsEditingTests {
    func testTheScriptEditorCompletesFromTheCatalogTheVariablesAndTheLatestResponse() async throws {
        try changeExternally { $0.defaultEnvironment.variables = [Variable(key: "token", value: "t"), Variable(key: "tenant", value: "a")] }
        let scripts = try openRequest()
        scripts.phase = .postResponse
        let exchange = RequestExchange(
            projectID: project,
            requestID: request.id,
            startedAt: Date(),
            environmentName: nil,
            request: nil,
            outcome: .response(HTTPResponseRecord(
                statusCode: 200,
                headers: [],
                body: Data(#"{"user":{"id":1}}"#.utf8),
                url: "https://api.test/me",
                startedAt: Date(),
                duration: 0.1
            ))
        )

        await scripts.loadResponseShape(from: exchange)
        let members = scripts.completions(in: "rq.res", cursor: 6)
        let names = try XCTUnwrap(scripts.completions(in: #"rq.environment.get("te"#, cursor: 22))
        let keys = scripts.completions(in: "rq.response.json().u", cursor: 20)

        XCTAssertEqual(members?.items.map(\.label), ["response"])
        XCTAssertEqual(members?.items.first?.kind, .namespace)
        XCTAssertEqual(names.items.map(\.label), ["tenant"])
        XCTAssertEqual(names.nameCharacters, .variableName)
        XCTAssertEqual(keys?.items.map(\.label), ["user"])
        XCTAssertTrue(scripts.opensCompletion(".", before: 3, in: "rq."))
    }

    func testAVariableNameSaysWhereItIsDefinedButNeverItsValue() throws {
        let login = RequestItem(name: "Login", kind: .http(HTTPRequestSpec(url: "https://api.test/login")))
        try changeExternally { document in
            document.defaultEnvironment.variables = [Variable(key: "token", value: "secret-value")]
            try document.insert(.request(login), into: nil)
            try document.updateRequest(login.id) { $0.scripts.postResponse = "rq.environment.set('token', 1)\nrq.globals.set('session', 2)" }
        }
        let scripts = try openRequest()

        let names = try XCTUnwrap(scripts.completions(in: #"rq.variables.get(""#, cursor: 18))
        let summaries = Dictionary(uniqueKeysWithValues: names.items.map { ($0.label, $0.summary) })

        XCTAssertEqual(summaries["token"], "In Default. Set by the post-response script of “Login”.")
        XCTAssertEqual(summaries["session"], "Set by the post-response script of “Login”.")
        XCTAssertFalse(names.items.contains { $0.summary?.contains("secret-value") == true })
    }

    func testProblemsMarkASyntaxErrorAndAMemberThatDoesntWorkWhereTheScriptRuns() async throws {
        let scripts = try openRequest()

        scripts.source = "rq.response.code\nconst = 1"
        await releaseAutosave()
        await waitUntil("the check") { scripts.diagnostics.text == scripts.source && scripts.diagnostics.items.count == 2 }

        let items = scripts.diagnostics.items
        XCTAssertEqual(items.first?.severity, .error)
        XCTAssertTrue(items.first?.message.hasPrefix("SyntaxError") ?? false)
        XCTAssertEqual(items.last?.message, "rq.response works only in stream and post-response scripts.")
    }

    func testNamesScriptsSetCountAsDefinedWhereTheyCanBe() throws {
        let login = RequestItem(name: "Login", kind: .http(HTTPRequestSpec(url: "https://api.test/login")))
        try changeExternally { [folder] document in
            try document.insert(.request(login), into: nil)
            try document.updateRequest(login.id) { $0.scripts.postResponse = "rq.environment.set('session', rq.response.json().token)" }
            try document.updateFolder(folder.id) { $0.scripts.preRequest = "rq.variables.set('signature', 'abc')" }
        }

        let inside = fixture.model.tokenContext(for: project, request: request.id)
        let outside = fixture.model.tokenContext(for: project, request: login.id)

        let session = try XCTUnwrap(inside.entries["session"])
        XCTAssertTrue(session.isSetByScript)
        let token = try XCTUnwrap(TemplateParser.tokens(in: "{{session}}").first)
        XCTAssertEqual(inside.tooltip(for: token), "Set by the post-response script of “Login”")
        XCTAssertNotNil(inside.entries["signature"], "Its folder's pre-request script sets it before it resolves")
        XCTAssertNotNil(outside.entries["session"], "An environment's name counts wherever it is set")
        XCTAssertNil(outside.entries["signature"], "A run-local name only where its script runs first")
    }
}

/// A stream script: its own phase, its placeholder, and its handlers' parameters.
@MainActor
extension ScriptsEditingTests {
    func testAStreamScriptCompletesItsHandlersParameterAndSavesAsItsOwnPhase() async throws {
        let scripts = try openRequest()
        scripts.phase = .stream

        scripts.source = "rq.onEvent(event => event.da)"
        let items = scripts.completions(in: scripts.source, cursor: 28)
        await releaseAutosave()
        await waitUntil("the save") { self.stored?.scripts.stream == "rq.onEvent(event => event.da)" }

        XCTAssertEqual(items?.items.map(\.label), ["data"])
        XCTAssertEqual(stored?.scripts.preRequest, "")
        XCTAssertTrue(ScriptsPane.placeholder(for: .stream, kind: .http).contains("event stream"))
        XCTAssertTrue(ScriptsPane.placeholder(for: .stream, kind: .webSocket).contains("rq.onMessage"))
        let folder = ScriptsPane.placeholder(for: .stream, kind: nil)
        XCTAssertTrue(folder.contains("rq.onEvent") && folder.contains("rq.onMessage"), "A folder's script serves every kind")
    }
}
