import Foundation
import Observation
import XCTest

extension XCTestCase {
    /// Returns once `condition` holds, re-checking whenever an observable value it reads changes.
    @MainActor
    func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async {
        let done = expectation(description: description)
        let waiting = Task { @MainActor in
            while !condition() {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = condition()
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        waiting.cancel()
    }

    /// Returns once `sleeper` has `count` sleeps waiting, such as the time limit of the call a stream script is in, or
    /// fails the test after a bounded wait instead of hanging the suite.
    @MainActor
    func waitForDeadline(_ sleeper: TestSleeper, count: Int = 1) async {
        let armed = expectation(description: "\(count) deadline armed")
        let waiting = Task {
            await sleeper.waitForWaiting(count)
            armed.fulfill()
        }
        await fulfillment(of: [armed], timeout: 30)
        waiting.cancel()
    }
}
