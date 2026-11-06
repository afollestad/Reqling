#if DEBUG
import Foundation
import ReqlingKit

/// The `scripts` scene's additions to Acme API, made only in that scene so no other capture shows a script badge:
/// Users' and Create user's scripts, and a cached run of Create user whose tests mostly pass, with what it printed.
@MainActor
enum ScreenshotScripts {
    static let usersPostResponse = """
    rq.test("responds within 500 ms", () => {
      rq.expect(rq.response.responseTime).to.be.below(500)
    })
    """

    static let createUserPreRequest = """
    rq.request.headers.upsert("Idempotency-Key", crypto.randomUUID())
    """

    static let createUserPostResponse = """
    const user = rq.response.json()

    rq.test("creates the user", () => {
      rq.expect(rq.response.code).to.equal(201)
      rq.expect(user.name).to.equal(rq.environment.get("name"))
    })

    rq.test("assigns the default role", () => {
      rq.expect(user.roles).to.include("viewer")
    })

    rq.test("sends a welcome email", () => {
      rq.expect(user.welcomeEmailSent).to.be.true
    })

    // Later requests read {{userId}} from here.
    rq.environment.set("userId", String(user.id))
    console.log("Created user", user.id)
    """

    static func apply(to document: inout ProjectDocument, users: RequestNodeID, createUser: RequestNodeID) throws {
        try document.updateFolder(users) { $0.scripts.postResponse = usersPostResponse }
        try document.updateRequest(createUser) { request in
            request.scripts = ScriptSet(preRequest: createUserPreRequest, postResponse: createUserPostResponse)
        }
    }

    static func cachedRun(of request: RequestNodeID, startedAt: Date) -> CachedRun {
        let body = #"{"id":43,"name":"Grace Hopper","email":"grace@acme.dev","roles":["viewer"],"welcomeEmailSent":false}"#
        let response = HTTPResponseRecord(
            statusCode: 201,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json; charset=utf-8")],
            body: Data(body.utf8),
            url: "https://api.acme.dev/users",
            startedAt: startedAt,
            duration: 0.112,
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )
        let sent = ResolvedHTTPRequest(
            method: "POST",
            url: "https://api.acme.dev/users",
            headers: [
                KeyValuePair(key: "Authorization", value: "Bearer ••••••••"),
                KeyValuePair(key: "Idempotency-Key", value: "3f6c1d2e-8a4b-4c5d-9e7f-0a1b2c3d4e5f")
            ],
            bodyPreview: nil,
            bodyByteCount: 0,
            scriptChangedHeaders: ["idempotency-key"]
        )
        return CachedRun(request: request, sent: sent, outcome: .response(response), scriptReport: report)
    }

    private static var report: ScriptReport {
        ScriptReport(phases: [
            ScriptPhaseReport(phase: .preRequest, levels: [ScriptLevelReport(kind: .request, name: "Create user")]),
            ScriptPhaseReport(
                phase: .postResponse,
                levels: [
                    ScriptLevelReport(kind: .folder, name: "Users", tests: [ScriptTestReport(name: "responds within 500 ms", result: .passed)]),
                    ScriptLevelReport(kind: .request, name: "Create user", tests: [
                        ScriptTestReport(name: "creates the user", result: .passed),
                        ScriptTestReport(name: "assigns the default role", result: .passed),
                        ScriptTestReport(name: "sends a welcome email", result: .failed, message: "expected false to be true")
                    ])
                ],
                console: [ScriptConsoleEntry(level: 1, severity: .log, text: "Created user 43")],
                variableChanges: [ScriptVariableChange(scope: .environment, key: "userId", isUnset: false, isSecret: false)]
            )
        ])
    }
}
#endif
