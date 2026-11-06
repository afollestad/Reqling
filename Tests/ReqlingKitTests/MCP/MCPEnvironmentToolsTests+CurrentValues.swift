import Foundation
import MCP
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

extension MCPEnvironmentToolsTests {
    private var defaultScope: CurrentValueScope {
        get throws {
            .environment(project, try fixture.document(project).defaultEnvironment.id)
        }
    }

    func testCurrentValuesAreListedWithSecretValuesWithheld() async throws {
        _ = try await fixture.success("create_variables", ["project": projectArgument, "variables": [["key": "token", "value": "saved"]]])
        fixture.library.currentValues.apply([
            "token": .value(TemplateVariable(value: "s3cr3t-current", isSecret: true)),
            "userId": .value(TemplateVariable(value: "42")),
            "gone": .unset
        ], in: try defaultScope)

        let listed = try await fixture.success("list_variables", ["project": projectArgument])
        let current = try XCTUnwrap(listed["currentValues"]?.arrayValue)
        let everything = try await fixture.success("list_variables", ["project": projectArgument, "includeAllEnvironments": true])

        XCTAssertEqual(current.map { $0["key"] }, ["gone", "token", "userId"])
        XCTAssertEqual(current[0]["unset"], true)
        XCTAssertEqual(current[1]["secret"], true)
        XCTAssertNil(current[1]["value"], "A secret current value is never returned")
        XCTAssertEqual(current[2]["value"], "42")
        XCTAssertEqual(everything["environments"]?.arrayValue?[1]["currentValues"]?.arrayValue?.count, 3)
    }

    func testResettingCurrentValuesByKeyOrAll() async throws {
        let scope = try defaultScope
        fixture.library.currentValues.apply([
            "a": .value(TemplateVariable(value: "1")),
            "b": .value(TemplateVariable(value: "2")),
            "c": .unset
        ], in: scope)

        let missing = await fixture.failure("reset_current_values", ["project": projectArgument, "keys": ["a", "nope"]])
        _ = try await fixture.success("reset_current_values", ["project": projectArgument, "keys": ["a"]])
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["b", "c"])

        _ = try await fixture.success("reset_current_values", ["project": projectArgument])
        XCTAssertTrue(fixture.library.currentValues.values(in: scope).isEmpty)
        XCTAssertTrue(missing.contains("no current value `nope`"), missing)
    }

    func testSavingCurrentValuesMakesThemSavedValuesAndDropsThem() async throws {
        let scope = try defaultScope
        fixture.library.currentValues.apply([
            "token": .value(TemplateVariable(value: "s3cr3t-current", isSecret: true)),
            "gone": .unset
        ], in: scope)

        let refused = await fixture.failure("save_current_values", ["project": projectArgument, "keys": ["token", "gone"]])
        let saved = try await fixture.success("save_current_values", ["project": projectArgument, "keys": ["token"]])

        XCTAssertTrue(refused.contains("no current value to save for `gone`"), refused)
        XCTAssertEqual(saved["variables"]?.arrayValue?.first?["secret"], true)
        XCTAssertNil(saved["variables"]?.arrayValue?.first?["value"])
        XCTAssertEqual(try fixture.document(project).defaultEnvironment.variables.first { $0.key == "token" }?.value, "s3cr3t-current")
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["gone"])
    }

    func testUpdatingAVariableDropsItsCurrentValue() async throws {
        _ = try await fixture.success("create_variables", ["environment": "Global", "variables": [["key": "region", "value": "eu"]]])
        fixture.library.currentValues.apply(["region": .value(TemplateVariable(value: "us"))], in: .global)

        _ = try await fixture.success("update_variables", ["environment": "Global", "variables": [["key": "region", "value": "ap"]]])

        XCTAssertTrue(fixture.library.currentValues.values(in: .global).isEmpty)
    }
}
