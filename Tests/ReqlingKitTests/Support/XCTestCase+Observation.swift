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
}
