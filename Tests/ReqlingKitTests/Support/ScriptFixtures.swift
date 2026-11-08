import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import Synchronization

/// Runs scripts in the real `ReqlingScriptRunner`, which `swift test` builds beside this bundle, over the runtime in the
/// repository. Its time limit passes only when the test calls `deadline.wake()`, so no test depends on wall time.
@MainActor
struct ScriptFixtures {
    let deadline = TestSleeper(returnsAtOnce: false)

    nonisolated static var helper: URL {
        Bundle(for: ScriptFixtureBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ReqlingScriptRunner")
    }

    /// `Sources/ReqlingScriptRunner/Runtime`, from this file's place in the repository.
    nonisolated static var runtime: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ReqlingScriptRunner/Runtime", isDirectory: true)
    }

    var runner: HelperScriptRunner {
        HelperScriptRunner(executable: Self.helper, runtimeDirectory: Self.runtime, sleep: deadline.sleep)
    }

    /// The real helper with a real time limit, counting the phases handed to it.
    nonisolated static func countingRunner() -> CountingScriptRunner {
        CountingScriptRunner(realRunner)
    }

    /// The real helper with a real time limit, for suites that never let a script run that long.
    nonisolated static var realRunner: HelperScriptRunner {
        HelperScriptRunner(executable: helper, runtimeDirectory: runtime)
    }

    /// A request named Login, for `http` unless another protocol is given.
    static func request(_ protocolName: String = "http") -> ScriptRequestSnapshot {
        ScriptRequestSnapshot(
            protocolName: protocolName,
            method: protocolName == "http" ? "POST" : nil,
            url: "{{base}}/login",
            headers: [ScriptRow(name: "Accept", value: "application/json")],
            query: protocolName == "grpc" ? [] : [ScriptRow(name: "page", value: "1")],
            body: protocolName == "http" ? ScriptRequestBody(mode: "raw", raw: #"{"user": "{{user}}"}"#) : nil,
            service: protocolName == "grpc" ? "greeter.Greeter" : nil,
            rpc: protocolName == "grpc" ? "SayHello" : nil,
            messages: protocolName == "http" ? [] : [#"{"name": "Ada"}"#]
        )
    }

    static func input(
        _ phase: ScriptPhase,
        _ sources: [String],
        variables: VariableLayers = VariableLayers(),
        request: ScriptRequestSnapshot = ScriptFixtures.request(),
        response: ScriptResponseSnapshot? = nil,
        stream: ScriptStreamSetup? = nil,
        cookies: [ScriptCookie] = [],
        limits: ScriptLimits = .standard,
        iteration: (index: Int, count: Int) = (0, 1)
    ) -> ScriptRunnerInput {
        let kinds: [ScriptLevelKind] = sources.count == 1 ? [.request] : [.project] + Array(repeating: .folder, count: sources.count - 2) + [.request]
        let levels = sources.enumerated().map { index, source in
            let path = "level-\(index).\(phase.fileSuffix).js"
            return ScriptLevelSource(kind: kinds[index], name: "Level \(index)", path: path, source: source)
        }
        return ScriptRunnerInput(
            phase: phase,
            levels: levels,
            variables: variables,
            info: ScriptRunInfo(
                requestName: "Login",
                requestID: "request-id",
                protocolName: request.protocolName,
                environmentName: "Staging",
                defaultEnvironmentName: "Default",
                iteration: iteration.index,
                iterationCount: iteration.count
            ),
            request: request,
            response: response,
            stream: stream ?? (phase == .stream ? opening(for: request.protocolName) : nil),
            cookies: cookies,
            runtimeDirectory: "",
            limits: limits
        )
    }

    /// What a stream opened with when a test doesn't say: a 200 event stream with JSON, a WebSocket that chose
    /// `chat`, or a call with metadata; replies can be sent except on an event stream.
    static func opening(for protocolName: String) -> ScriptStreamSetup {
        switch protocolName {
        case "websocket":
            ScriptStreamSetup(
                opening: .webSocket(code: 101, headers: [ScriptRow(name: "Upgrade", value: "websocket")], subprotocol: "chat"),
                canSend: true
            )
        case "grpc":
            ScriptStreamSetup(opening: .grpc(metadata: [ScriptRow(name: "x-trace", value: "t1")]), canSend: true)
        default:
            ScriptStreamSetup(
                opening: .eventStream(code: 200, status: "OK", headers: [ScriptRow(name: "Content-Type", value: "text/event-stream")]),
                canSend: false
            )
        }
    }

    static func event(_ data: String, _ number: Int, type: String? = nil, id: String? = nil) -> ScriptStreamItem {
        ScriptStreamItem(number: number, content: .event(ScriptStreamEvent(id: id, event: type, data: data, retry: nil)))
    }

    /// A WebSocket text message received.
    static func message(_ text: String, _ number: Int) -> ScriptStreamItem {
        ScriptStreamItem(number: number, content: .socketMessage(ScriptSocketMessage(direction: "received", text: text, base64: nil)))
    }

    static func grpcMessage(_ json: String, _ number: Int) -> ScriptStreamItem {
        ScriptStreamItem(number: number, content: .grpcMessage(json))
    }

    /// Runs to the end and collects every event.
    func run(_ input: ScriptRunnerInput, blobs: [Data] = []) async -> ScriptRun {
        let execution = runner.run(input, blobs: blobs, timeLimit: .seconds(10))
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
        }
        return ScriptRun(events: events, termination: await execution.termination())
    }

    /// Runs a stream phase over `items`, handed over at once (they wait for its top level), then ends its input and
    /// collects every event.
    func stream(_ input: ScriptRunnerInput, items: [ScriptStreamItem]) async -> ScriptRun {
        let execution = runner.stream(input, timeLimit: .seconds(10))
        for item in items {
            _ = execution.deliver(item)
        }
        execution.end()
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
        }
        let ended = await execution.termination()
        return ScriptRun(events: events, termination: ended.reason, streamEnd: ended)
    }
}

/// What one phase reported.
struct ScriptRun {
    let events: [ScriptRunnerEvent]
    let termination: ScriptTermination
    /// A stream phase's end, with the item it had in hand.
    var streamEnd: ScriptStreamTermination?

    var console: [String] {
        events.compactMap { event in
            if case .console(_, _, let text) = event {
                return text
            }
            return nil
        }
    }

    struct Test {
        let name: String
        let result: ScriptTestResult
        let message: String?
    }

    var tests: [Test] {
        events.compactMap { event in
            if case .test(_, let name, let result, let message) = event {
                return Test(name: name, result: result, message: message)
            }
            return nil
        }
    }

    var writes: [VariableWrite] {
        events.compactMap { event in
            if case .variable(let write) = event {
                return write
            }
            return nil
        }
    }

    var changes: [ScriptRequestChange] {
        events.compactMap { event in
            if case .request(let change) = event {
                return change
            }
            return nil
        }
    }

    var cookieWrites: [ScriptCookieWrite] {
        events.compactMap { event in
            if case .cookie(let write) = event {
                return write
            }
            return nil
        }
    }

    var flow: [ScriptFlowRequest] {
        events.compactMap { event in
            if case .flow(let request) = event {
                return request
            }
            return nil
        }
    }

    var failures: [Int: ScriptError] {
        var failures: [Int: ScriptError] = [:]
        for case .levelFailed(let level, let error) in events {
            failures[level] = error
        }
        return failures
    }

    struct Failure {
        /// The stream item whose call it failed in; `nil` in a top level.
        let item: Int?
        let level: Int
        let error: ScriptError
    }

    /// Every level failure in order, each with the call it happened in.
    var callFailures: [Failure] {
        var item: Int?
        var failures: [Failure] = []
        for event in events {
            switch event {
            case .callStarted(let started):
                item = started
            case .callFinished:
                item = nil
            case .levelFailed(let level, let error):
                failures.append(Failure(item: item, level: level, error: error))
            default:
                break
            }
        }
        return failures
    }

    /// The items a stream phase handed to its handlers, in order.
    var calls: [Int] {
        events.compactMap { event in
            if case .callStarted(let item) = event {
                return item
            }
            return nil
        }
    }

    var registeredHandlers: Int? {
        events.lazy.compactMap { event in
            if case .registered(let handlers) = event {
                return handlers
            }
            return nil
        }.first
    }

    var sends: [ScriptOutgoingMessage] {
        events.compactMap { event in
            if case .send(_, let message) = event {
                return message
            }
            return nil
        }
    }
}

private final class ScriptFixtureBundleToken {}

/// Hands every phase to another runner, counting them, so a test can tell whether scripts ran at all.
final class CountingScriptRunner: ScriptRunning {
    private let base: any ScriptRunning
    private let count = Mutex(0)
    private let streamCount = Mutex(0)

    init(_ base: any ScriptRunning) {
        self.base = base
    }

    /// One-shot phases: pre-request and post-response.
    var launches: Int {
        count.withLock { $0 }
    }

    var streamLaunches: Int {
        streamCount.withLock { $0 }
    }

    func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution {
        count.withLock { $0 += 1 }
        return base.run(input, blobs: blobs, timeLimit: timeLimit)
    }

    func stream(_ input: ScriptRunnerInput, timeLimit: Duration) -> ScriptStreamExecution {
        streamCount.withLock { $0 += 1 }
        return base.stream(input, timeLimit: timeLimit)
    }
}
