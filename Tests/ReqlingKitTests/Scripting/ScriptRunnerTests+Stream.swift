import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// Stream scripts in the real helper: the top level registers handlers, then each item reaches them in turn.
extension ScriptRunnerTests {
    func testHandlersRunInLevelAndRegistrationOrderEachAwaitedBeforeTheNext() async {
        let run = await fixtures.stream(ScriptFixtures.input(.stream, [
            """
            rq.onEvent(async (event) => {
              await new Promise((resolve) => setTimeout(resolve, 1))
              console.log("project first", event.data)
            })
            rq.onEvent((event) => console.log("project second", event.data))
            """,
            """
            const r = rq.response
            console.log(r.code, r.status, r.headers.get("content-type"), r.events === undefined, rq.info.phase, pm.info.eventName)
            rq.onEvent((event) => console.log("request", event.json().n, event.id, event.event, event.retry))
            """
        ]), items: [
            ScriptFixtures.event(#"{"n": 1}"#, 1, type: "tick", id: "a"),
            ScriptFixtures.event(#"{"n": 2}"#, 3)
        ])

        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.registeredHandlers, 3)
        XCTAssertEqual(run.calls, [1, 3])
        XCTAssertEqual(run.console, [
            "200 OK text/event-stream true stream stream",
            #"project first {"n": 1}"#, #"project second {"n": 1}"#, "request 1 a tick null",
            #"project first {"n": 2}"#, #"project second {"n": 2}"#, "request 2 null null null"
        ])
        XCTAssertTrue(run.callFailures.isEmpty)
    }

    func testAHandlerThatThrowsFailsOnlyItsCallAndALevelWhoseTopLevelThrewGetsNone() async {
        let run = await fixtures.stream(ScriptFixtures.input(.stream, [
            """
            rq.onEvent((event) => {
              if (event.data === "bad") throw new TypeError("nope")
              console.log("first", event.data)
            })
            rq.onEvent((event) => console.log("second", event.data))
            """,
            "rq.onEvent(() => console.log(\"never\"))\nthrow new Error(\"setup\")"
        ]), items: [ScriptFixtures.event("good", 1), ScriptFixtures.event("bad", 2), ScriptFixtures.event("later", 3)])

        XCTAssertEqual(run.registeredHandlers, 2, "The level that threw registers nothing")
        XCTAssertEqual(run.console, ["first good", "second good", "second bad", "first later", "second later"])
        XCTAssertEqual(run.callFailures.map(\.item), [nil, 2])
        XCTAssertEqual(run.callFailures.map(\.level), [1, 0])
        XCTAssertEqual(run.callFailures[0].error.message, "setup")
        XCTAssertEqual(run.callFailures[1].error.name, "TypeError")
        XCTAssertEqual(run.callFailures[1].error.line, 2)
    }

    /// A handler registers only from the top level, for its own protocol; registering for another kind of stream is no
    /// error, so a folder's script serves every protocol.
    func testHandlersRegisterOnlyAtTheTopLevelAndOnlyForTheirOwnStream() async {
        let run = await fixtures.stream(ScriptFixtures.input(.stream, ["""
            rq.onEvent(() => console.log("an event"))
            try { rq.onMessage(5) } catch (error) { console.log(error.message) }
            rq.onMessage((message) => {
              try { rq.onMessage(() => {}) } catch (error) { console.log(error.message) }
              console.log(message.text, message.direction, message.isBinary, message.base64, message.json().k)
            })
            """], request: ScriptFixtures.request("websocket")), items: [ScriptFixtures.message(#"{"k": "v"}"#, 1)])

        XCTAssertEqual(run.registeredHandlers, 1)
        XCTAssertEqual(run.console, [
            "rq.onMessage needs a function to run on each message.",
            "rq.onMessage registers a handler only while a stream script's top level runs, not from a handler or later.",
            #"{"k": "v"} received false null v"#
        ])
    }

    /// Each call ends once its handlers settle: a timer fires while its call still waits, and is dropped once the call
    /// settles. A call that can never settle fails, its pending test with it, while the next call still runs.
    func testACallEndsWhenItsHandlersSettleAndOneThatCanNeverFailsAlone() async {
        let run = await fixtures.stream(ScriptFixtures.input(.stream, ["""
            rq.onEvent(async (event) => {
              setTimeout(() => console.log("unawaited"), 0)
              if (event.data === "hang") {
                rq.test("pending", () => new Promise(() => {}))
                await new Promise(() => {})
              }
              console.log("handled", event.data)
            })
            """]), items: [ScriptFixtures.event("hang", 1), ScriptFixtures.event("next", 2)])

        XCTAssertEqual(run.console, ["unawaited", "handled next"])
        XCTAssertEqual(run.callFailures.map(\.item), [1])
        XCTAssertEqual(run.callFailures.first?.error.message, "A handler awaited something that never finished.")
        XCTAssertEqual(run.tests.map(\.name), ["pending"])
        XCTAssertEqual(run.tests.first?.message, "The test didn't finish before its script ended.")
    }

    func testEachCallHasLimitsOfItsOwnWhileStateCarriesAcrossCalls() async {
        var limits = ScriptLimits()
        limits.tests = 2
        limits.variableWrites = 2
        let run = await fixtures.stream(ScriptFixtures.input(.stream, ["""
            let count = 0
            rq.onEvent(() => {
              count += 1
              rq.variables.set("n", count)
              rq.environment.set("m", count)
              for (const name of ["a", "b", "c"]) rq.test(name, () => {})
              try { rq.variables.set("over", 1) } catch (error) { console.log(error.message) }
              console.log(rq.variables.get("n"), rq.environment.get("m"))
            })
            """], limits: limits), items: [ScriptFixtures.event("1", 1), ScriptFixtures.event("2", 2)])

        XCTAssertEqual(run.tests.map(\.name), ["a", "b", "a", "b"])
        XCTAssertEqual(run.console, [
            "Further tests in this handler call were not reported.",
            "Scripts can set at most 2 values in one handler call.",
            "1 1",
            "Further tests in this handler call were not reported.",
            "Scripts can set at most 2 values in one handler call.",
            "2 2"
        ])
        XCTAssertEqual(run.writes.map(\.key), ["n", "m", "n", "m"])
    }

    func testRqSendReportsTextJSONAndBinaryOnAWebSocket() async {
        let run = await fixtures.stream(ScriptFixtures.input(.stream, ["""
            rq.send("hello")
            rq.send({ a: 1 })
            rq.send(new Uint8Array([1, 2, 3]).subarray(1))
            rq.send(new Uint8Array([9]).buffer)
            try { rq.send(undefined) } catch (error) { console.log(error.message) }
            rq.onMessage((message) => rq.send("echo " + message.text))
            """], request: ScriptFixtures.request("websocket")), items: [ScriptFixtures.message("x", 1)])

        XCTAssertEqual(run.sends, [.text("hello"), .text(#"{"a":1}"#), .binary(Data([2, 3])), .binary(Data([9])), .text("echo x")])
        XCTAssertEqual(run.console, ["rq.send needs text or a value JSON can hold, not undefined."])
    }

    func testRqSendTakesOnlyJSONOnGRPCAndNothingOnAnEventStream() async {
        let call = await fixtures.stream(ScriptFixtures.input(.stream, ["""
            rq.send({ name: "Ada" })
            rq.send('{"name": "Bo"}')
            try { rq.send("not json") } catch (error) { console.log(error.name) }
            try { rq.send(new Uint8Array(1)) } catch (error) { console.log(error.message) }
            rq.onMessage((message) => console.log(message.json().name, message.text()))
            console.log(rq.response.metadata.get("x-trace"), rq.response.code === undefined)
            """], request: ScriptFixtures.request("grpc")), items: [ScriptFixtures.grpcMessage(#"{"name":"Cy"}"#, 1)])
        let stream = await fixtures.stream(
            ScriptFixtures.input(.stream, ["try { rq.send(\"x\") } catch (error) { console.log(error.message) }"]),
            items: []
        )

        XCTAssertEqual(call.sends, [.text(#"{"name":"Ada"}"#), .text(#"{"name": "Bo"}"#)])
        XCTAssertEqual(call.console, [
            "SyntaxError", "rq.send sends a gRPC message as JSON: an object, or its text.", "t1 true", #"Cy {"name":"Cy"}"#
        ])
        XCTAssertEqual(stream.console, ["rq.send can't reply on an event stream, which only receives."])
        XCTAssertEqual(stream.registeredHandlers, 0)
    }

    func testRqSendThrowsOnceTheConnectionStopsTakingMessages() async {
        let input = ScriptFixtures.input(.stream, ["""
            rq.send("open")
            rq.onMessage(() => {
              try { rq.send("reply") } catch (error) { console.log(error.message) }
            })
            """], request: ScriptFixtures.request("websocket"))
        let execution = fixtures.runner.stream(input, timeLimit: .seconds(10))
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
            if case .registered = event {
                // Written in order, so the close arrives before the item.
                execution.closeSending()
                _ = execution.deliver(ScriptFixtures.message("x", 1))
                execution.end()
            }
        }
        let run = ScriptRun(events: events, termination: await execution.termination().reason)

        XCTAssertEqual(run.sends, [.text("open")])
        XCTAssertEqual(run.console, ["rq.send can't send: the connection is closed."])
    }

    func testAHandlerCallPastTheTimeLimitIsKilledNamingItsItem() async {
        let input = ScriptFixtures.input(.stream, ["rq.onEvent((event) => { if (event.data === \"slow\") while (true) {} })"])
        let execution = fixtures.runner.stream(input, timeLimit: .seconds(10))
        for (number, data) in ["fast", "slow", "after"].enumerated() {
            _ = execution.deliver(ScriptFixtures.event(data, number + 1))
        }
        for await event in execution.events where event == .callStarted(item: 2) {
            await fixtures.deadline.waitForWaiting(1)
            fixtures.deadline.wake()
        }

        let ended = await execution.termination()
        XCTAssertEqual(ended, ScriptStreamTermination(reason: .timedOut, item: 2, abandoned: 1))
        XCTAssertEqual(execution.deliver(ScriptFixtures.event("late", 4)), .refused)
    }

    func testATopLevelPastTheTimeLimitIsKilledBeforeAnyCall() async {
        let input = ScriptFixtures.input(.stream, ["rq.onEvent(() => {}); console.log(\"setting up\"); while (true) {}"])
        let execution = fixtures.runner.stream(input, timeLimit: .seconds(10))
        _ = execution.deliver(ScriptFixtures.event("waiting", 1))
        for await event in execution.events {
            if case .console = event {
                await fixtures.deadline.waitForWaiting(1)
                fixtures.deadline.wake()
            }
        }

        let ended = await execution.termination()
        XCTAssertEqual(ended, ScriptStreamTermination(reason: .timedOut, item: nil, abandoned: 1))
    }

    /// Stop lets the call in hand finish, then ends the phase; what waited never reaches a handler.
    func testStoppingFinishesTheCallInHandAndDropsWhatWaits() async {
        let input = ScriptFixtures.input(.stream, ["""
            rq.onEvent(async (event) => {
              console.log("start", event.data)
              await new Promise((resolve) => setTimeout(resolve, 1))
              console.log("end", event.data)
            })
            """])
        let execution = fixtures.runner.stream(input, timeLimit: .seconds(10))
        var dropped: Int?
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
            if case .registered = event {
                // Item 1 goes straight to the helper; the others wait, and Stop drops them.
                for number in 1...3 {
                    _ = execution.deliver(ScriptFixtures.event(String(number), number))
                }
                dropped = execution.stop()
            }
        }
        let run = ScriptRun(events: events, termination: await execution.termination().reason)

        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.console, ["start 1", "end 1"])
        XCTAssertEqual(execution.deliver(ScriptFixtures.event("late", 4)), .refused)
    }

    /// A stream script that registers nothing has nothing to wait for: its helper exits without its input closing.
    func testAStreamScriptWithNoHandlersEndsAfterItsTopLevel() async {
        let execution = fixtures.runner.stream(ScriptFixtures.input(.stream, ["console.log(\"only this\")"]), timeLimit: .seconds(10))
        _ = execution.deliver(ScriptFixtures.event("ignored", 1))
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
        }
        let ended = await execution.termination()
        let run = ScriptRun(events: events, termination: ended.reason)

        XCTAssertEqual(ended, ScriptStreamTermination(reason: .finished, item: nil, abandoned: 0))
        XCTAssertEqual(run.registeredHandlers, 0)
        XCTAssertEqual(run.console, ["only this"])
    }

    func testAStreamPhaseWithoutWhatItOpenedWithIsRefused() async {
        var input = ScriptFixtures.input(.stream, ["1"])
        input.stream = nil

        let run = await fixtures.run(input)

        XCTAssertEqual(run.termination, .failed("Reqling's script runner couldn't read what to run."))
    }
}
