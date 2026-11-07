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
        limits: ScriptLimits = .standard,
        iteration: (index: Int, count: Int) = (0, 1)
    ) -> ScriptRunnerInput {
        let kinds: [ScriptLevelKind] = sources.count == 1 ? [.request] : [.project] + Array(repeating: .folder, count: sources.count - 2) + [.request]
        let levels = sources.enumerated().map { index, source in
            let path = "level-\(index).\(phase == .preRequest ? "pre" : "post").js"
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
            runtimeDirectory: "",
            limits: limits
        )
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
}

/// What one phase reported.
struct ScriptRun {
    let events: [ScriptRunnerEvent]
    let termination: ScriptTermination

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
}

private final class ScriptFixtureBundleToken {}

/// Hands every phase to another runner, counting them, so a test can tell whether scripts ran at all.
final class CountingScriptRunner: ScriptRunning {
    private let base: any ScriptRunning
    private let count = Mutex(0)

    init(_ base: any ScriptRunning) {
        self.base = base
    }

    var launches: Int {
        count.withLock { $0 }
    }

    func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution {
        count.withLock { $0 += 1 }
        return base.run(input, blobs: blobs, timeLimit: timeLimit)
    }
}
