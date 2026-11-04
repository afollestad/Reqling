import Foundation
import XCTest

/// Holds every sleeper until `releaseAll()`, so debounced work runs exactly when a test says.
@MainActor
final class SleepGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        waiting.count
    }

    func sleep() async {
        await withCheckedContinuation { waiting.append($0) }
    }

    func releaseAll() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}

/// Yields to the main actor until `condition` holds, failing after a bounded number of turns rather than a clock.
@MainActor
func waitUntil(
    _ description: String,
    turns: Int = 2_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    for _ in 0..<turns {
        if condition() {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
}
