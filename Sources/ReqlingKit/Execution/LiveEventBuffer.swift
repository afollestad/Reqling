import Foundation
import Synchronization

/// The events between a live call or stream and its one receiver, in order: gRPC calls and event-stream responses
/// both deliver through one.
///
/// Messages are the lossy part: bounded by count and by payload bytes, so a lagging receiver costs at most the
/// budget however large the messages, with the oldest dropped first and counted per direction. Every other event
/// (the stream opening, initial metadata) is always kept, so none is ever lost uncounted. Each message gets its
/// `sequence` here, under the same lock that orders it, so sequences follow delivery order across both directions.
///
/// Whenever the drop totals have grown, the next event handed out is the one `omitted` makes from the new totals, and
/// one more comes before the end if they grew since. Reports therefore never outnumber the events delivered.
final class LiveEventBuffer<Event: Sendable>: Sendable {
    let messageLimit: Int
    let byteLimit: Int
    /// The event reporting the running drop totals, each superseding the last.
    private let omitted: @Sendable (_ sent: Int, _ received: Int) -> Event
    private let state = Mutex(State())

    init(messageLimit: Int, byteLimit: Int, omitted: @escaping @Sendable (_ sent: Int, _ received: Int) -> Event) {
        self.messageLimit = messageLimit
        self.byteLimit = byteLimit
        self.omitted = omitted
    }

    /// Messages never delivered: dropped for the budget, or skipped after `skipBacklog`.
    var dropped: (sent: Int, received: Int) {
        state.withLock { ($0.droppedSent, $0.droppedReceived) }
    }

    func appendControl(_ event: Event) {
        deliver { state in
            state.control.append((state.nextOrdinal, event))
            state.nextOrdinal += 1
        }
    }

    /// `make` builds the message from its sequence; `bytes` is what it holds in memory.
    func appendMessage(bytes: Int, isSent: Bool, _ make: (_ sequence: Int) -> Event) {
        let (messageLimit, byteLimit) = (self.messageLimit, self.byteLimit)
        deliver { state in
            let event = make(state.nextSequence)
            state.nextSequence += 1
            guard !state.isSkipping else {
                state.countDrop(isSent: isSent)
                return
            }
            state.messages.append(Message(ordinal: state.nextOrdinal, event: event, bytes: bytes, isSent: isSent))
            state.nextOrdinal += 1
            state.messageBytes += bytes
            // The newest message always stays, even one larger than the whole budget.
            while state.queuedMessages > 1, state.queuedMessages > messageLimit || state.messageBytes > byteLimit {
                state.dropOldestMessage()
            }
        }
    }

    /// Drops every queued message and any added later, counted, so a cancelled call never waits on a backlog. Events
    /// that are not messages still come through.
    func skipBacklog() {
        state.withLock { state in
            state.isSkipping = true
            while state.queuedMessages > 0 {
                state.dropOldestMessage()
            }
        }
    }

    /// Ends the stream once everything queued, and the final drop totals, have been taken.
    func finish() {
        let handoff = state.withLock { state -> (CheckedContinuation<Event?, Never>, Event?)? in
            state.isFinished = true
            guard let waiter = state.waiter else {
                return nil
            }
            state.waiter = nil
            return (waiter, state.popNext(omitted))
        }
        handoff.map { $0.0.resume(returning: $0.1) }
    }

    /// The next event, or `nil` once finished and drained. One receiver only.
    func next() async -> Event? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Event?? in
                if let event = state.popNext(omitted) {
                    return .some(event)
                }
                if state.isFinished {
                    return .some(nil)
                }
                state.waiter = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }

    /// Applies `change`, then hands the next event to a waiting receiver, outside the lock.
    private func deliver(_ change: (inout State) -> Void) {
        let handoff = state.withLock { state -> (CheckedContinuation<Event?, Never>, Event)? in
            change(&state)
            guard let waiter = state.waiter, let event = state.popNext(omitted) else {
                return nil
            }
            state.waiter = nil
            return (waiter, event)
        }
        handoff.map { $0.0.resume(returning: $0.1) }
    }

    private struct Message {
        let ordinal: Int
        let event: Event
        let bytes: Int
        let isSent: Bool
    }

    /// Two queues, merged by `ordinal` on the way out, so dropping a message never disturbs the other events. Each
    /// queue advances a head index and compacts occasionally, rather than shifting on every removal.
    private struct State {
        var control: [(ordinal: Int, event: Event)] = []
        var controlHead = 0
        var messages: [Message] = []
        var messageHead = 0
        var messageBytes = 0
        var nextOrdinal = 0
        var nextSequence = 0
        var droppedSent = 0
        var droppedReceived = 0
        /// The totals the last report carried.
        var reportedSent = 0
        var reportedReceived = 0
        var isSkipping = false
        var isFinished = false
        var waiter: CheckedContinuation<Event?, Never>?

        var queuedMessages: Int {
            messages.count - messageHead
        }

        mutating func countDrop(isSent: Bool) {
            if isSent {
                droppedSent += 1
            } else {
                droppedReceived += 1
            }
        }

        mutating func dropOldestMessage() {
            let message = messages[messageHead]
            messageBytes -= message.bytes
            countDrop(isSent: message.isSent)
            messageHead += 1
            compact()
        }

        mutating func popNext(_ omitted: (_ sent: Int, _ received: Int) -> Event) -> Event? {
            if droppedSent != reportedSent || droppedReceived != reportedReceived {
                reportedSent = droppedSent
                reportedReceived = droppedReceived
                return omitted(droppedSent, droppedReceived)
            }
            let nextControl = controlHead < control.count ? control[controlHead].ordinal : nil
            let nextMessage = messageHead < messages.count ? messages[messageHead].ordinal : nil
            if let nextControl, nextMessage.map({ nextControl < $0 }) ?? true {
                defer { controlHead += 1 }
                return control[controlHead].event
            }
            guard nextMessage != nil else {
                return nil
            }
            let message = messages[messageHead]
            messageBytes -= message.bytes
            messageHead += 1
            compact()
            return message.event
        }

        private mutating func compact() {
            if messageHead > 1_024, messageHead * 2 > messages.count {
                messages.removeFirst(messageHead)
                messageHead = 0
            }
            if controlHead > 64, controlHead * 2 > control.count {
                control.removeFirst(controlHead)
                controlHead = 0
            }
        }
    }
}
