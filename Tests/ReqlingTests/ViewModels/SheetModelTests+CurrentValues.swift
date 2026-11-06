import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

@testable import Reqling

extension SheetModelTests {
    private func seedStaging() throws -> (EnvironmentID, CurrentValueScope) {
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "token", value: "saved")])
        try fixture.library.mutate(project) { $0.environments = [staging] }
        let scope = CurrentValueScope.environment(project, staging.id)
        fixture.library.currentValues.apply([
            "token": .value(TemplateVariable(value: "s3cr3t", isSecret: true)),
            "userId": .value(TemplateVariable(value: "42")),
            "gone": .unset
        ], in: scope)
        return (staging.id, scope)
    }

    func testTheSheetListsTheSelectedEnvironmentsCurrentValues() throws {
        let (staging, _) = try seedStaging()
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = staging

        XCTAssertEqual(editor.currentValueRows, [
            CurrentValueRow(key: "gone", value: nil, isSecret: false, overridesSavedValue: false),
            CurrentValueRow(key: "token", value: "s3cr3t", isSecret: true, overridesSavedValue: true),
            CurrentValueRow(key: "userId", value: "42", isSecret: false, overridesSavedValue: false)
        ])

        editor.selectedID = editor.defaultEnvironment.id
        XCTAssertTrue(editor.currentValueRows.isEmpty)
    }

    func testResetIsStagedUntilDoneAndCancelKeepsTheValues() throws {
        let (staging, scope) = try seedStaging()
        let cancelled = EnvironmentEditorModel(projectID: project, app: fixture.model)
        cancelled.selectedID = staging
        cancelled.resetCurrentValue("userId")
        cancelled.resetAllCurrentValues()
        XCTAssertTrue(cancelled.currentValueRows.isEmpty)
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).count, 3, "Nothing changes until Done")

        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = staging
        editor.resetCurrentValue("userId")

        XCTAssertEqual(editor.currentValueRows.map(\.key), ["gone", "token"])
        XCTAssertTrue(editor.save())
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["gone", "token"])
    }

    func testResetAllOnDoneDropsEveryCurrentValueOfTheEnvironment() throws {
        let (staging, scope) = try seedStaging()
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = staging
        editor.resetAllCurrentValues()

        XCTAssertTrue(editor.save())

        XCTAssertTrue(fixture.library.currentValues.values(in: scope).isEmpty)
    }

    func testSaveAsValuePutsTheValueInTheDraftAndDropsItOnDone() throws {
        let (staging, scope) = try seedStaging()
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = staging

        editor.saveCurrentValueAsValue("token")
        editor.saveCurrentValueAsValue("userId")
        editor.saveCurrentValueAsValue("gone")

        XCTAssertEqual(editor.selected.variables.map(\.key), ["token", "userId"])
        XCTAssertEqual(editor.selected.variables.map(\.isSecret), [true, false])
        XCTAssertEqual(editor.currentValueRows.map(\.key), ["gone"])
        XCTAssertTrue(editor.save())
        let saved = try XCTUnwrap(fixture.library.document(project)?.environment(staging)).variables
        XCTAssertEqual(saved.map(\.value), ["s3cr3t", "42"])
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["gone"])
    }

    /// Editing a saved variable in the draft hides its current value, which Done then drops.
    func testEditingASavedVariableHidesItsCurrentValue() throws {
        let (staging, scope) = try seedStaging()
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = staging

        editor.selected.variables[0].value = "typed"

        XCTAssertEqual(editor.currentValueRows.map(\.key), ["gone", "userId"])
        XCTAssertTrue(editor.save())
        XCTAssertEqual(fixture.library.currentValues.values(in: scope).keys.sorted(), ["gone", "userId"])
    }

    func testGlobalCurrentValuesShowUnderGlobal() throws {
        fixture.library.currentValues.apply(["region": .value(TemplateVariable(value: "eu"))], in: .global)
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        editor.selectedID = editor.globalEnvironment.id

        XCTAssertEqual(editor.currentValueRows.map(\.key), ["region"])
    }
}
