import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

extension RequestRunnerTests {
    func testRunsResolveCurrentValuesAndMaskSecretOnes() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        fixture.library.currentValues.apply(
            ["path": .value(TemplateVariable(value: "current-secret", isSecret: true))],
            in: .environment(fixtureProject.id, fixtureProject.staging)
        )
        workspace.updateProject(fixtureProject.id) { $0.activeEnvironmentID = fixtureProject.staging }
        let runner = makeRunner()

        let exchange = await runner.run(fixtureProject.request, in: fixtureProject.id)
        let masked = runner.maskingSecrets(in: fixtureProject.id)("echo: current-secret")

        XCTAssertEqual(body(exchange), "GET /current-secret -")
        XCTAssertEqual(exchange.request?.url.contains("current-secret"), false, "The stored request shows it masked")
        XCTAssertEqual(masked, "echo: \(TemplateResolver.mask)")
    }

    func testAMarkerHidesTheSavedValueSoTheRunFallsBackToDefault() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        fixture.library.currentValues.apply(["path": .unset], in: .environment(fixtureProject.id, fixtureProject.staging))
        workspace.updateProject(fixtureProject.id) { $0.activeEnvironmentID = fixtureProject.staging }

        let exchange = await makeRunner().run(fixtureProject.request, in: fixtureProject.id)

        XCTAssertEqual(body(exchange), "GET /default -")
    }
}
