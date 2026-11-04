import Foundation
import ReqlingKit
import Synchronization
import XCTest

/// The real runner against `/bin/sh` and `/bin/sleep`, which every macOS install has.
final class ProcessCommandRunnerTests: XCTestCase {
    func testCapturesBothStreamsAndTheExitCode() async throws {
        let script = "printf out; printf err >&2; exit 3"

        let result = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            currentDirectory: nil,
            timeout: .seconds(30)
        )

        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardOutputText, "out")
        XCTAssertEqual(result.standardErrorText, "err")
    }

    func testArgumentsAreNeverShellExpanded() async throws {
        let result = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/bin/echo"),
            arguments: ["$HOME", "a;b", "*"],
            currentDirectory: nil,
            timeout: .seconds(30)
        )

        XCTAssertEqual(result.standardOutputText, "$HOME a;b *\n")
    }

    func testAnExpiredTimeoutThrows() async {
        // The injected sleep returns at once, so the timeout fires without waiting on the clock.
        let runner = ProcessCommandRunner(sleep: { _ in })

        do {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], currentDirectory: nil, timeout: .seconds(5))
            XCTFail("Expected a timeout")
        } catch let error as CommandError {
            XCTAssertEqual(error, .timedOut(executable: "sleep", after: .seconds(5)))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testAMissingExecutableIsALaunchFailure() async {
        do {
            _ = try await ProcessCommandRunner().run(
                URL(fileURLWithPath: "/nonexistent/protoc"),
                arguments: [],
                currentDirectory: nil,
                timeout: .seconds(30)
            )
            XCTFail("Expected a launch failure")
        } catch CommandError.launchFailed(let executable, _) {
            XCTAssertEqual(executable, "protoc")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testATimeoutReturnsWhileAGrandchildHoldsThePipes() async throws {
        // A wrapper that backgrounds its child instead of `exec`ing it. `terminate()` signals the whole process
        // group, so the child ignores SIGTERM to outlive the wrapper while holding the inherited pipes; it reports
        // its PID only once the trap is set.
        let script = #"/bin/sh -c 'trap "" TERM; echo $$ > "$1"; exec /bin/sleep 60' sh "$1" & wait"#
        try await assertTimeoutReturns(script: script)
    }

    func testAProcessIgnoringSIGTERMIsKilledAfterTheGracePeriod() async throws {
        let script = #"trap "" TERM; echo $$ > "$1"; exec /bin/sleep 60"#
        try await assertTimeoutReturns(script: script)
    }

    /// Runs `script` with a FIFO path as `$1`. The timeout fires only once the script has written a PID to it, so the
    /// interruption meets the state under test; the grace period then expires at once.
    private func assertTimeoutReturns(script: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fifo = directory.file("ready")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, file: file, line: line)
        let gate = FIFOGate(fifo: fifo)
        let runner = ProcessCommandRunner(sleep: { _ in await gate.wait() })
        let returned = expectation(description: "run returned")
        let task = Task {
            defer { returned.fulfill() }
            do {
                _ = try await runner.run(
                    URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script, "sh", fifo.path],
                    currentDirectory: nil,
                    timeout: .seconds(60)
                )
                XCTFail("Expected a timeout", file: file, line: line)
            } catch {
                XCTAssertEqual(error as? CommandError, .timedOut(executable: "sh", after: .seconds(60)), file: file, line: line)
            }
        }
        await fulfillment(of: [returned], timeout: 20)
        if let pid = gate.pid {
            kill(pid, SIGKILL)
        }
        _ = await task.value
    }
}

/// The first wait blocks until the script writes its PID to the FIFO; later waits return at once.
private final class FIFOGate: Sendable {
    private let fifo: URL
    private let state = Mutex<(opened: Bool, pid: Int32?)>((false, nil))

    init(fifo: URL) {
        self.fifo = fifo
    }

    var pid: Int32? {
        state.withLock { $0.pid }
    }

    func wait() async {
        let isFirst = state.withLock { state in
            defer { state.opened = true }
            return !state.opened
        }
        guard isFirst else {
            return
        }
        let fifo = fifo
        // Opening a FIFO for reading blocks until the writer opens it, so read off the cooperative pool.
        let text = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = FileHandle(forReadingAtPath: fifo.path)?.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: String(bytes: data, encoding: .utf8) ?? "")
            }
        }
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        state.withLock { $0.pid = pid }
    }
}
