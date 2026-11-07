import Foundation
@testable import ReqlingKit
import XCTest

/// gRPC calls as steps of a folder or project run.
@MainActor
extension GRPCRunnerTests {
    /// A server's own status fails its step rather than interrupting it, and a call ends at its deadline, which a run's
    /// stream limit doesn't shorten.
    func testAServerStatusAndADeadlineFailTheirSteps() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary", messages: [#"{"text": "fail"}"#]), server: server)
        settings.update { $0.grpcDeadlineSeconds = 1 }
        let batches = BatchRunner(runner: makeRunner())
        let plan = BatchRunPlan(
            scope: BatchRunScope(projectID: project, folderID: nil),
            requests: [request],
            streamLimit: StreamLimit(maxDuration: .milliseconds(1))
        )

        let rejected = try await batches.begin(plan, mayPromptForTrust: false).finished()
        try fixture.library.mutate(project) { document in
            try document.updateRequest(request) { $0.kind = .grpc(self.echoSpec("Unary", messages: [#"{"text": "hang"}"#])) }
        }
        let late = try await batches.begin(plan, mayPromptForTrust: false).finished()

        XCTAssertEqual(rejected.counts, BatchStepCounts(failed: 1))
        XCTAssertEqual(rejected.notableSteps.first?.summary?.status, .grpc(code: 5, name: "NOT_FOUND"))
        XCTAssertEqual(late.counts, BatchStepCounts(failed: 1))
        XCTAssertEqual(late.notableSteps.first?.summary?.status, .grpc(code: 4, name: "DEADLINE_EXCEEDED"))
    }
}
