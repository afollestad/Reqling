import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

extension AppModelTests {
    func testTheTrustQuestionShowsAndItsAnswerReachesTheRun() async throws {
        XCTAssertTrue(fixture.component.requestRunner.trustDecider === model, "The window answers the runner's questions")

        let question = Task { await model.decideScriptTrust(projectName: "Shared API", files: ["project.pre.js"]) }
        await waitUntil("the question shows") { self.model.scriptTrustPending != nil }
        XCTAssertEqual(model.scriptTrustPending?.title, "Run the scripts in “Shared API”?")
        XCTAssertTrue(model.scriptTrustPending?.message.hasSuffix("project.pre.js") ?? false)
        model.answerScriptTrust(true)

        let answer = await question.value
        XCTAssertEqual(answer, true)
        XCTAssertNil(model.scriptTrustPending)
    }

    func testANewTrustQuestionAnswersTheOpenOneNotNow() async throws {
        let first = Task { await model.decideScriptTrust(projectName: "One", files: []) }
        await waitUntil("the first question shows") { self.model.scriptTrustPending?.projectName == "One" }
        let second = Task { await model.decideScriptTrust(projectName: "Two", files: []) }
        await waitUntil("the second question shows") { self.model.scriptTrustPending?.projectName == "Two" }
        model.answerScriptTrust(false)

        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertNil(firstAnswer)
        XCTAssertEqual(secondAnswer, false)
    }

    func testTheProjectsScriptTrustCanBeChanged() throws {
        let project = try makeProject()
        XCTAssertEqual(model.scriptTrust(for: project), .trusted, "A project created here trusts its own scripts")

        model.setScriptTrust(.declined, for: project)

        XCTAssertEqual(fixture.component.workspaceState.projectState(project).scriptTrust, .declined)
    }
}
