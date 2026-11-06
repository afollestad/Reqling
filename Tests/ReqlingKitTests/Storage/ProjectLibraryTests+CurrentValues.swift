import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

extension ProjectLibraryTests {
    private func projectWithStaging() throws -> (ProjectID, staging: EnvironmentID) {
        let id = try fixture.library.createProject(named: "Current")
        let staging = RequestEnvironment(name: "Staging", variables: [
            Variable(key: "token", value: "saved"),
            Variable(key: "host", value: "staging.example.com")
        ])
        try fixture.library.mutate(id) { $0.environments.append(staging) }
        return (id, staging.id)
    }

    func testEditingASavedValueDropsOnlyThatKeysCurrentValue() throws {
        let (id, staging) = try projectWithStaging()
        let scope = CurrentValueScope.environment(id, staging)
        fixture.library.currentValues.apply([
            "token": .value(TemplateVariable(value: "from script")),
            "host": .value(TemplateVariable(value: "local")),
            "scriptOnly": .value(TemplateVariable(value: "x"))
        ], in: scope)

        try fixture.library.mutate(id) { document in
            document.updateEnvironment(staging) { $0.variables[0].value = "edited" }
        }

        XCTAssertEqual(Set(fixture.library.currentValues.values(in: scope).keys), ["host", "scriptOnly"])
    }

    func testAddingAVariableForACurrentOnlyKeyDropsItsCurrentValue() throws {
        let (id, staging) = try projectWithStaging()
        let scope = CurrentValueScope.environment(id, staging)
        fixture.library.currentValues.apply(["scriptOnly": .value(TemplateVariable(value: "x"))], in: scope)

        try fixture.library.mutate(id) { document in
            document.updateEnvironment(staging) { $0.variables.append(Variable(key: "scriptOnly", value: "saved")) }
        }

        XCTAssertTrue(fixture.library.currentValues.values(in: scope).isEmpty)
    }

    func testEditsElsewhereInTheProjectKeepCurrentValues() throws {
        let (id, staging) = try projectWithStaging()
        let scope = CurrentValueScope.environment(id, staging)
        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "from script"))], in: scope)

        try fixture.library.mutate(id) { document in
            try document.insert(.request(.http("Health")), into: nil)
            document.defaultEnvironment.variables.append(Variable(key: "token", value: "default's"))
        }

        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["token"])
    }

    /// An outside edit (a `git pull`) reloads without going through `mutate`, so it leaves current values alone.
    func testAnOutsideEditKeepsCurrentValues() throws {
        let id = try fixture.library.createProject(named: "Outside")
        let defaultID = try XCTUnwrap(fixture.library.document(id)).defaultEnvironment.id
        let scope = CurrentValueScope.environment(id, defaultID)
        try fixture.library.mutate(id) { $0.defaultEnvironment.variables.append(Variable(key: "token", value: "saved")) }
        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "from script"))], in: scope)
        let file = try fixture.contents("environments/default.json", in: id)

        try fixture.write(file.replacingOccurrences(of: "\"saved\"", with: "\"pulled\""), to: "environments/default.json", in: id)
        fixture.library.reload(id)

        XCTAssertEqual(fixture.library.document(id)?.defaultEnvironment.variables.first?.value, "pulled")
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["token"])
    }

    func testDeletingAnEnvironmentOrTheProjectDropsItsCurrentValues() throws {
        let (id, staging) = try projectWithStaging()
        let defaultID = try XCTUnwrap(fixture.library.document(id)).defaultEnvironment.id
        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "x"))], in: .environment(id, staging))
        fixture.library.currentValues.apply(["a": .value(TemplateVariable(value: "1"))], in: .environment(id, defaultID))

        try fixture.library.mutate(id) { $0.environments.removeAll { $0.id == staging } }

        XCTAssertEqual(Array(fixture.library.currentValues.snapshot(for: id).environments.keys), [defaultID])

        try fixture.library.deleteProject(id)

        XCTAssertFalse(fixture.library.currentValues.hasValues(for: id))
    }

    func testEditingGlobalDropsItsChangedKeysCurrentValues() throws {
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "region", value: "eu"), Variable(key: "tier", value: "free")] }
        fixture.library.currentValues.apply([
            "region": .value(TemplateVariable(value: "us")),
            "tier": .value(TemplateVariable(value: "pro"))
        ], in: .global)

        try fixture.library.mutateGlobalEnvironment { $0.variables[1].isEnabled = false }

        XCTAssertEqual(fixture.library.currentValues.values(in: .global).keys.sorted(), ["region"])
    }

    func testSavingACurrentValueWritesItAsTheSavedValue() throws {
        let (id, staging) = try projectWithStaging()
        let scope = CurrentValueScope.environment(id, staging)
        fixture.library.currentValues.apply([
            "token": .value(TemplateVariable(value: "fresh", isSecret: true)),
            "newKey": .value(TemplateVariable(value: "added")),
            "same": .value(TemplateVariable(value: "staging.example.com"))
        ], in: scope)

        try fixture.library.saveCurrentValue("token", in: scope)
        try fixture.library.saveCurrentValue("newKey", in: scope)

        let variables = try XCTUnwrap(fixture.library.document(id)?.environment(staging)).variables
        XCTAssertEqual(variables.first { $0.key == "token" }.map { [$0.value, "\($0.isSecret)"] }, ["fresh", "true"])
        XCTAssertEqual(variables.first { $0.key == "newKey" }?.value, "added")
        XCTAssertFalse(try fixture.contents("environments/staging.json", in: id).contains("fresh"), "A secret's value goes to the Keychain")
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["same"])
        XCTAssertThrowsError(try fixture.library.saveCurrentValue("missing", in: scope))
    }

    /// A current value equal to the saved one changes nothing on disk, but saving it still drops the current value.
    func testSavingACurrentValueEqualToTheSavedOneStillDropsIt() throws {
        let (id, staging) = try projectWithStaging()
        let scope = CurrentValueScope.environment(id, staging)
        fixture.library.currentValues.apply(["host": .value(TemplateVariable(value: "staging.example.com"))], in: scope)

        try fixture.library.saveCurrentValue("host", in: scope)

        XCTAssertTrue(fixture.library.currentValues.values(in: scope).isEmpty)
    }

    func testRunScopesSeeCurrentValuesOverSavedOnesAndMarkersHideThem() throws {
        let (id, staging) = try projectWithStaging()
        let document = try XCTUnwrap(fixture.library.document(id))
        fixture.library.currentValues.apply([
            "token": .value(TemplateVariable(value: "current", isSecret: true)),
            "host": .unset
        ], in: .environment(id, staging))

        let scope = VariableScope(
            global: fixture.library.globalEnvironment,
            document: document,
            activeEnvironmentID: staging,
            currentValues: fixture.library.currentValues.snapshot(for: id)
        )

        XCTAssertEqual(scope.lookup("token")?.value, "current")
        XCTAssertEqual(scope.lookup("token")?.isSecret, true)
        XCTAssertEqual(scope.lookup("token")?.isCurrentValue, true)
        XCTAssertEqual(scope.lookup("token")?.source, .environment(id: staging, name: "Staging"))
        XCTAssertNil(scope.lookup("host"))
    }
}
