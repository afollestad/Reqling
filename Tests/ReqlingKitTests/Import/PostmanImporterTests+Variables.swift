import Foundation
@testable import ReqlingKit
import XCTest

/// The collection's variables, its environments and globals, and the built-ins Reqling doesn't generate.
extension PostmanImporterTests {
    func testCollectionVariablesGoToDefaultAndEnvironmentsComeAlong() throws {
        let plan = try petstore(files: [try Self.file("staging.postman_environment"), try Self.file("workspace.postman_globals")])

        XCTAssertEqual(plan.defaultVariables.filter { !$0.isSecret }.map(\.key), ["baseUrl", "user"])
        XCTAssertEqual(plan.environments.map(\.name), ["Staging"])
        let staging = try XCTUnwrap(plan.environments.first?.variables)
        XCTAssertEqual(staging.map(\.key), ["baseUrl", "apiSecret", "retries"])
        XCTAssertEqual(staging.map(\.isSecret), [false, true, false])
        XCTAssertEqual(staging.last?.value, "3", "a number is written as JSON writes it")
        XCTAssertEqual(staging.last?.isEnabled, false)
        XCTAssertEqual(plan.globals.map(\.key), ["region"])
        XCTAssertEqual(plan.counts.environments, 1)
        XCTAssertEqual(plan.environmentChanges, [
            ImportEnvironmentChange(environment: "Staging", isNew: true, added: ["baseUrl", "apiSecret", "retries"], updated: [])
        ])
    }

    /// Postman's "Default" is Reqling's Default, and "Global" names the environment every project shares.
    func testEnvironmentsNamedLikeReqlingsOwnLandWhereTheyFit() throws {
        let files = try ["Default", "global"].map { name in
            try PostmanFile.read(Data(#"{"name": "\#(name)", "values": [{"key": "host", "value": "\#(name)"}]}"#.utf8), named: "\(name).json")
        }
        let plan = try self.plan(items: "[]", extra: #""variable": [{"key": "host", "value": "collection"}]"#, files: files)

        XCTAssertEqual(plan.defaultVariables.map(\.value), ["Default"], "the environment's value wins over the collection's")
        XCTAssertEqual(plan.environments.map(\.name), ["Global (Postman)"])
        XCTAssertEqual(plan.notes.map(\.message), ["“global” is the name of the environment every project shares, so it's “Global (Postman)” here."])
    }

    func testBuiltInsReqlingDoesntGenerateAndItemVariablesAreNoted() throws {
        let plan = try self.plan(items: """
        [{"name": "R", "variable": [{"key": "local", "value": "1"}],
          "request": {"url": "https://x/{{$randomEmail}}?n={{$randomBankAccount}}&c={{$randomCatchPhrase}}"}}]
        """)

        XCTAssertEqual(messages(plan, "R"), [
            "Its variables “local” aren't imported, since Reqling keeps variables in environments; add them to one.",
            "It uses {{$randomBankAccount}} and {{$randomCatchPhrase}}, which Reqling doesn't generate."
        ])
        XCTAssertTrue(try petstore().notes.contains(ImportNote(
            owner: .node(["Pets", "Get pet"]), topic: .variable, message: "It uses {{$randomBankAccount}}, which Reqling doesn't generate."
        )), "a turned-off row's value counts too")
    }
}
