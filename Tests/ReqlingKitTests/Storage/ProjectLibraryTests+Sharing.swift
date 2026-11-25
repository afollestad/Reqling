import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

extension ProjectLibraryTests {
    /// A project that uses Global's `baseUrl` and `token` in a request, `host` from an environment's value, `region`
    /// through a script, and `tenant` only through `rq.globals`, and defines `apiKey` in its own Default.
    private func projectUsingGlobal() throws -> ProjectID {
        try fixture.library.mutateGlobalEnvironment { global in
            global.variables = [
                Variable(key: "baseUrl", value: "https://api"),
                Variable(key: "token", value: "global-s3cret", isSecret: true),
                Variable(key: "host", value: "example.com"),
                Variable(key: "region", value: "eu"),
                Variable(key: "tenant", value: "acme"),
                Variable(key: "apiKey", value: "global-key"),
                Variable(key: "unused", value: "x"),
                Variable(key: "disabled", value: "y", isEnabled: false)
            ]
        }
        let id = try fixture.library.createProject(named: "Shared")
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "apiKey", value: "project-key"),
                Variable(key: "origin", value: "https://{{host}}")
            ]
            document.scripts = ScriptSet(preRequest: "rq.variables.get('region'); rq.globals.get('tenant');")
            let request = RequestItem(name: "List", kind: .http(HTTPRequestSpec(url: "{{baseUrl}}/users?key={{apiKey}}&t={{token}}&d={{disabled}}")))
            document.items = [.request(request)]
        }
        return id
    }

    func testSharingOffersTheGlobalVariablesAProjectUsesAndLacks() throws {
        let id = try projectUsingGlobal()

        let offer = fixture.library.globalVariablesOffer(for: id)

        XCTAssertEqual(offer.variables.map(\.key), ["baseUrl", "host", "region", "token"])
        XCTAssertEqual(offer.readThroughGlobals, ["tenant"])
    }

    func testCopyingGlobalVariablesAddsThemToDefaultWithThisPersonsValues() throws {
        let id = try projectUsingGlobal()

        try fixture.library.copyGlobalVariables(["baseUrl", "token"], into: id)

        let variables = try XCTUnwrap(fixture.library.document(id)).defaultEnvironment.variables
        XCTAssertEqual(variables.map(\.key), ["apiKey", "origin", "baseUrl", "token"])
        XCTAssertEqual(variables.last?.value, "global-s3cret")
        XCTAssertEqual(variables.last?.isSecret, true)
        XCTAssertEqual(fixture.library.globalVariablesOffer(for: id).variables.map(\.key), ["host", "region"])
    }

    /// A person's own secret values, as in a project they may only view, change no file, and drop the current values they
    /// make stale, as an edit would.
    func testSettingSecretValuesWritesNoFile() throws {
        let id = try fixture.library.createProject(named: "Viewed")
        try fixture.library.mutate(id) { $0.defaultEnvironment.variables = [Variable(key: "token", value: "", isSecret: true)] }
        let document = try XCTUnwrap(fixture.library.document(id))
        let token = try XCTUnwrap(document.defaultEnvironment.variables.first)
        let key = SecretKey.variable(token.id, in: document.defaultEnvironment.id)
        let scope = CurrentValueScope.environment(id, document.defaultEnvironment.id)
        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "stale", isSecret: true))], in: scope)
        let before = try fixture.contents("project.json", in: id)
        var changes: [LibraryChange] = []
        fixture.library.changeObserver = { changes.append($0) }

        try fixture.library.setSecretValues([key: "mine", "variable.unknown": "ignored"], in: id)

        XCTAssertEqual(fixture.library.document(id)?.defaultEnvironment.variables.first?.value, "mine")
        XCTAssertEqual(try fixture.secrets.secrets(for: .project(id)), [key: "mine"])
        XCTAssertEqual(try fixture.contents("project.json", in: id), before)
        XCTAssertTrue(fixture.library.currentValues.values(in: scope).isEmpty)
        XCTAssertTrue(changes.contains(.project(id)))
    }
}
