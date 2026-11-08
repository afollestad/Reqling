import Foundation
@testable import ReqlingKit
import XCTest

/// Postman's variables merged into Reqling's environments: Postman's value wins, but never blanks or unhides a value.
final class PostmanEnvironmentMergeTests: XCTestCase {
    func testPostmansValueWinsAndEachVariableKeepsItsID() {
        let token = Variable(key: "token", value: "stored", isSecret: true)
        let host = Variable(key: "host", value: "stored")
        let off = Variable(key: "off", value: "kept", isEnabled: true)
        var environment = RequestEnvironment(name: "Staging", variables: [token, host, off])

        let (added, updated) = PostmanEnvironmentMerge.merge([
            Variable(key: "host", value: "postman"),
            Variable(key: "token", value: "", isSecret: false),
            Variable(key: "off", value: "kept", isEnabled: false),
            Variable(key: "new", value: "1")
        ], into: &environment)

        XCTAssertEqual(environment.variables.map(\.id).prefix(3), [token.id, host.id, off.id])
        XCTAssertEqual(environment.variables.map(\.value), ["stored", "postman", "kept", "1"], "an empty value never blanks a filled one")
        XCTAssertEqual(environment.variables.map(\.isSecret), [true, false, false, false], "a secret stays secret")
        XCTAssertEqual(environment.variables.map(\.isEnabled), [true, true, false, true])
        XCTAssertEqual(added, ["new"])
        XCTAssertEqual(updated, ["host", "off"])
    }

    func testFilesMergeIntoTheEnvironmentOfTheirNameOrAreAdded() throws {
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "host", value: "old")])
        var targets = PostmanEnvironmentMerge.Targets(
            global: .global(variables: [Variable(key: "region", value: "us")]),
            defaultEnvironment: RequestEnvironment(name: "Default"),
            environments: [staging]
        )
        let files = try [
            #"{"name": "staging", "values": [{"key": "host", "value": "new"}]}"#,
            #"{"name": "Production", "values": [{"key": "host", "value": "prod"}]}"#,
            #"{"name": "Globals", "_postman_variable_scope": "globals", "values": [{"key": "region", "value": "eu"}]}"#
        ].enumerated().map { try PostmanFile.read(Data($1.utf8), named: "\($0).json") }

        let (changes, touched) = PostmanEnvironmentMerge.merge(files, into: &targets)

        XCTAssertEqual(targets.environments.map(\.name), ["Staging", "Production"], "matched ignoring case, keeping Reqling's name")
        XCTAssertEqual(targets.environments.first?.id, staging.id)
        XCTAssertEqual(targets.environments.map { $0.variables.first?.value }, ["new", "prod"])
        XCTAssertEqual(targets.global.variables.map(\.value), ["eu"])
        XCTAssertEqual(changes, [
            PostmanEnvironmentChange(environment: "Staging", isNew: false, added: [], updated: ["host"]),
            PostmanEnvironmentChange(environment: "Production", isNew: true, added: ["host"], updated: []),
            PostmanEnvironmentChange(environment: "Global", isNew: false, added: [], updated: ["region"])
        ])
        XCTAssertEqual(touched, [staging.id, targets.environments[1].id, RequestEnvironment.globalID])
    }
}
