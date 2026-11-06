import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

@testable import Reqling

extension AppModelTests {
    func testEditorsSeeCurrentValuesAndRebuildWhenScriptsChangeThem() throws {
        let project = try makeProject()
        let defaultID = try XCTUnwrap(fixture.library.document(project)).defaultEnvironment.id
        try fixture.library.mutate(project) { $0.defaultEnvironment.variables = [Variable(key: "token", value: "saved")] }
        XCTAssertEqual(model.tokenContext(for: project).entries["token"]?.displayValue, "saved")

        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "fresh", isSecret: true))], in: .environment(project, defaultID))

        let context = model.tokenContext(for: project)
        XCTAssertEqual(context.entries["token"], TemplateTokenContext.Entry(
            displayValue: TemplateResolver.mask,
            sourceName: "Default, current value set by a script"
        ))
    }
}
