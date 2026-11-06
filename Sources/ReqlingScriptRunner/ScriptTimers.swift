import Foundation
import JavaScriptCore

/// `setTimeout` and `setInterval` for one level, run by the level's drain loop on this one thread. Timers fire in due
/// order, and in the order they were set when due together, as browsers run them.
final class ScriptTimers {
    private struct Timer {
        let callback: JSValue
        var dueAt: TimeInterval
        let interval: TimeInterval?
        var order: Int
    }

    private var timers: [Int: Timer] = [:]
    private var nextID = 1
    private var nextOrder = 0

    var isEmpty: Bool {
        timers.isEmpty
    }

    static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func add(_ callback: JSValue, delayMilliseconds: Double, repeats: Bool) -> Int {
        let id = nextID
        nextID += 1
        // An interval fires at most once a millisecond, so one left running can't spin the loop.
        let delay = max(delayMilliseconds.isFinite ? delayMilliseconds : 0, repeats ? 1 : 0) / 1_000
        timers[id] = Timer(callback: callback, dueAt: Self.now + delay, interval: repeats ? delay : nil, order: takeOrder())
        return id
    }

    func clear(_ id: Int) {
        timers[id] = nil
    }

    /// The timer to fire next and when it's due.
    func next() -> (id: Int, dueAt: TimeInterval)? {
        timers.min { ($0.value.dueAt, $0.value.order) < ($1.value.dueAt, $1.value.order) }.map { ($0.key, $0.value.dueAt) }
    }

    /// Removes a one-shot timer, or schedules an interval's next run, then calls it.
    func fire(_ id: Int) {
        guard var timer = timers[id] else {
            return
        }
        if let interval = timer.interval {
            timer.dueAt = Self.now + interval
            timer.order = takeOrder()
            timers[id] = timer
        } else {
            timers[id] = nil
        }
        timer.callback.call(withArguments: [])
    }

    func removeAll() {
        timers.removeAll()
    }

    private func takeOrder() -> Int {
        nextOrder += 1
        return nextOrder
    }
}
