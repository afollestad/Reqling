import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// The real helper, batched so each launch checks several things.
@MainActor
final class ScriptRunnerTests: XCTestCase {
    let fixtures = ScriptFixtures()

    func testVariablesCarryAcrossLevelsAndResolveTemplatesAsARunDoes() async {
        let layers = VariableLayers(
            defaultEnvironment: VariableLayer(saved: [
                "base": TemplateVariable(value: "https://api"),
                "token": TemplateVariable(value: "s3cr3t", isSecret: true)
            ]),
            active: VariableLayer(saved: ["user": TemplateVariable(value: "ada")])
        )
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            rq.environment.set("session", "abc")
            rq.globals.set("region", { code: "eu" })
            console.log(rq.environment.get("user"), rq.defaultEnvironment.get("base"), rq.environment.name)
            """,
            """
            rq.variables.set("signature", rq.crypto.sha256(rq.environment.get("session")))
            console.log(rq.variables.replaceIn("{{base}}/{{user}}?s={{session}}"), rq.variables.get("region"))
            console.log(rq.variables.isSecret("token"), rq.environment.isSecret("user"), rq.variables.has("missing"))
            rq.environment.set("auth", "Bearer " + rq.variables.get("token"))
            rq.environment.unset("user")
            console.log(String(rq.environment.get("user")), JSON.stringify(Object.keys(rq.environment.toObject()).sort()))
            """
        ], variables: layers))

        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.console, [
            "ada https://api Staging",
            #"https://api/ada?s=abc {"code":"eu"}"#,
            "true false false",
            #"undefined ["auth","session"]"#
        ])
        XCTAssertEqual(run.writes.map(\.key), ["session", "region", "signature", "auth", "user"])
        XCTAssertEqual(run.writes.map(\.scope), [.environment, .global, .local, .environment, .environment])
        XCTAssertEqual(run.writes[3].isSecret, true, "A value holding a secret is secret")
        XCTAssertNil(run.writes[4].value)
        XCTAssertEqual(run.writes[2].value, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testValuesSetBeforeAThrowAreKeptAndTheErrorPointsAtTheScriptsLine() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            "rq.environment.set(\"kept\", \"1\")\n\nnull.boom()",
            "rq.environment.set(\"never\", \"1\")"
        ]))

        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.writes.map(\.key), ["kept"], "A pre-request phase stops at its first failed level")
        XCTAssertEqual(run.failures[0]?.line, 3)
        XCTAssertEqual(run.failures[0]?.name, "TypeError")
    }

    func testAPostResponsePhaseRunsEveryLevelPastAFailure() async {
        let response = ScriptResponseSnapshot.http(ScriptHTTPResponse(
            code: 200, status: "OK", headers: [], body: ScriptBlob(index: 0, size: 0), size: 0, truncated: false, responseTime: 1
        ))
        let input = ScriptFixtures.input(.postResponse, ["throw new Error(\"first\")", "console.log(\"second\")"], response: response)
        let run = await fixtures.run(input, blobs: [Data()])

        XCTAssertEqual(run.failures[0]?.message, "first")
        XCTAssertEqual(run.failures[0]?.line, 1)
        XCTAssertEqual(run.console, ["second"])
    }

    func testARunawayScriptIsKilledAtItsTimeLimitKeepingWhatItReported() async throws {
        let execution = fixtures.runner.run(
            ScriptFixtures.input(.preRequest, ["rq.environment.set(\"before\", \"1\"); console.log(\"looping\"); while (true) {}"]),
            blobs: [],
            timeLimit: .seconds(10)
        )
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
            if case .console = event {
                fixtures.deadline.wake()
            }
        }

        let termination = await execution.termination()
        XCTAssertEqual(termination, .timedOut)
        XCTAssertTrue(events.contains { if case .variable(let write) = $0 { return write.key == "before" } else { return false } })
    }

    /// Timers run on the helper's real clock, which a busy machine can stall for milliseconds, and an interval
    /// reschedules from when it actually fired. So nothing here races one timer against another: the timeouts are
    /// set back to back far apart, the interval resolves its own wait, and the later timeout proves it was cleared.
    func testAwaitTimersAndIntervalsRunInOrder() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        const order = []
        const timeouts = new Promise((resolve) => {
            setTimeout(() => { order.push("timeout 30"); resolve() }, 30)
            setTimeout(() => order.push("timeout 0"), 0)
        })
        let ticks = 0
        await new Promise((resolve) => {
            const interval = setInterval(() => { ticks += 1; if (ticks === 3) { clearInterval(interval); resolve() } }, 1)
        })
        await timeouts
        order.push("ticks " + ticks)
        console.log(order.join(", "))
        setTimeout(() => console.log("dropped"), 1000)
        """]))

        XCTAssertEqual(run.console, ["timeout 0, timeout 30, ticks 3"])
        XCTAssertEqual(run.failures.count, 0)
    }

    func testTestsReportPassesFailuresSkipsAndUnfinishedOnes() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        rq.test("sync passes", () => rq.expect(1).to.equal(1))
        rq.test("sync fails", () => rq.expect(1).to.equal(2))
        rq.test("async passes", async () => { await new Promise((r) => setTimeout(r, 1)); rq.expect([1, 2]).to.include(2) })
        rq.test("async fails", async () => { throw new Error("nope") })
        rq.test.skip("skipped", () => {})
        rq.test("never finishes", () => new Promise(() => {}))
        """]))

        XCTAssertEqual(run.tests.map(\.name), ["sync passes", "sync fails", "skipped", "async fails", "async passes", "never finishes"])
        XCTAssertEqual(run.tests.map(\.result), [.passed, .failed, .skipped, .failed, .passed, .failed])
        XCTAssertEqual(run.tests[1].message, "expected 1 to equal 2")
        XCTAssertEqual(run.tests[5].message, "The test didn't finish before its script ended.")
    }
}
