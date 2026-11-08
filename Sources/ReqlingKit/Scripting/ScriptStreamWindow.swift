import ReqlingScriptProtocol

/// What a stream phase's helper is given, decided without a process so its rules test directly. Items wait here, never
/// in the helper, which gets the next one only once it has finished the one before: so the time limit bounds each call
/// alone, and what waits stays bounded, counted, and droppable on Stop.
///
/// Items wait until the top level has registered its handlers, and are discarded uncounted if it registered none.
/// Past `limit` items or `byteLimit` bytes, the oldest waiting are dropped, as `LiveEventBuffer` drops what the window
/// falls behind on, always keeping the newest.
struct ScriptStreamWindow {
    enum Action: Equatable {
        case none
        case write(ScriptStreamItem)
        /// Tells the helper no more items come (`ScriptRunnerMessage.endOfItems`), which ends the phase once the item in
        /// hand is done. Its input stays open, for the replies that item's requests wait on.
        case endItems
    }

    let limit: Int
    let byteLimit: Int
    private var waiting: [ScriptStreamItem] = []
    private var waitingBytes = 0
    /// How many handlers the top level registered; `nil` while it still runs.
    private var handlers: Int?
    /// The item the helper is handling.
    private var inHand: Int?
    /// The stream ended: hand over what waits, then close.
    private var isEnding = false
    private var isStopped = false
    private var isEndOfItems = false
    private var isOver = false

    init(limit: Int, byteLimit: Int) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    mutating func deliver(_ item: ScriptStreamItem) -> (ScriptStreamDelivery, Action) {
        guard !isOver, !isStopped, !isEnding else {
            return (.refused, .none)
        }
        guard handlers != 0 else {
            return (.unneeded, .none)
        }
        if handlers != nil, inHand == nil, waiting.isEmpty {
            inHand = item.number
            return (.queued(dropped: 0), .write(item))
        }
        waiting.append(item)
        waitingBytes += item.byteCount
        var dropped = 0
        while waiting.count > 1, waiting.count > limit || waitingBytes > byteLimit {
            waitingBytes -= waiting.removeFirst().byteCount
            dropped += 1
        }
        return (.queued(dropped: dropped), .none)
    }

    mutating func registered(handlers count: Int) -> Action {
        handlers = count
        guard count > 0 else {
            waiting.removeAll()
            waitingBytes = 0
            return endItems()
        }
        return next()
    }

    mutating func finished(item: Int) -> Action {
        guard inHand == item else {
            return .none
        }
        inHand = nil
        return next()
    }

    /// Drops what waits, returning how many items it held, and ends the items at once: the helper holds no more than
    /// the item in hand, which it still finishes.
    mutating func stop() -> (Int, Action) {
        guard !isStopped, !isOver else {
            return (0, .none)
        }
        isStopped = true
        let dropped = waiting.count
        waiting.removeAll()
        waitingBytes = 0
        return (dropped, endItems())
    }

    mutating func end() -> Action {
        isEnding = true
        return next()
    }

    /// The helper exited: the item it had in hand, and how many waiting never reached it.
    mutating func over() -> (item: Int?, abandoned: Int) {
        isOver = true
        let ended = (item: inHand, abandoned: waiting.count)
        waiting.removeAll()
        waitingBytes = 0
        inHand = nil
        return ended
    }

    private mutating func next() -> Action {
        guard !isStopped, !isOver, inHand == nil else {
            return .none
        }
        if let handlers, handlers > 0, !waiting.isEmpty {
            let item = waiting.removeFirst()
            waitingBytes -= item.byteCount
            inHand = item.number
            return .write(item)
        }
        return isEnding && waiting.isEmpty ? endItems() : .none
    }

    private mutating func endItems() -> Action {
        guard !isEndOfItems else {
            return .none
        }
        isEndOfItems = true
        return .endItems
    }
}
