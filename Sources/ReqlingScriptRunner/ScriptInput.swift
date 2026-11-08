import Foundation
import ReqlingScriptProtocol

/// Reads framed input (`ScriptFraming`) from standard input as it arrives rather than to its end, so a stream phase can
/// start while Reqling still has items to write.
final class ScriptInputReader: @unchecked Sendable {
    enum Next {
        case frame(Data)
        /// Standard input closed between frames.
        case end
        /// It closed partway through a frame, or a length was out of bounds; nothing after can be trusted.
        case corrupt
    }

    private var frames = ScriptFraming.Reader()
    private var pending: [Data] = []
    private var isCorrupt = false
    /// Large enough that a 64 MB body arrives in a few hundred reads.
    private var buffer = [UInt8](repeating: 0, count: 256 * 1_024)

    /// Blocks until the next frame is in, or the input ends.
    func next() -> Next {
        while pending.isEmpty {
            guard !isCorrupt else {
                return .corrupt
            }
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                return count == 0 && !frames.hasPartialFrame ? .end : .corrupt
            }
            guard let complete = frames.append(Data(buffer[0..<count])) else {
                isCorrupt = true
                return .corrupt
            }
            pending += complete
        }
        return .frame(pending.removeFirst())
    }
}

/// What the reader thread hands the main thread, in every phase: a stream's items, in order, and whether `rq.send` can
/// still reply; and the replies to the requests scripts sent, by ID. Only this crosses threads; JavaScriptCore and
/// `EventWriter` stay on the main thread.
///
/// A reply arrives only for a fetch the main thread said it waits on (`expect`), so one a level left behind when it
/// ended (`forget`) is dropped as it arrives rather than holding its body until the phase ends.
final class ScriptInbox: @unchecked Sendable {
    /// A fetch's reply, with the body its `.response` carries.
    struct Reply {
        let reply: ScriptFetchReply
        let body: Data
    }

    private let condition = NSCondition()
    private var items: [ScriptStreamItem] = []
    private var replies: [Reply] = []
    private var expected: Set<Int> = []
    private var isEndOfItems = false
    /// The input ended, or a frame couldn't be read: nothing more arrives.
    private var isInputClosed = false
    private var isSendingOpen: Bool

    init(canSend: Bool) {
        isSendingOpen = canSend
    }

    var canSend: Bool {
        locked { isSendingOpen }
    }

    var isClosed: Bool {
        locked { isInputClosed }
    }

    /// The next item, waiting for one; `nil` once no more will come and every item was taken.
    func next() -> ScriptStreamItem? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty, !isEndOfItems, !isInputClosed {
            condition.wait()
        }
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// Notes a fetch whose reply to keep. Called before its event is written, so a reply can't beat it.
    func expect(_ id: Int) {
        locked { _ = expected.insert(id) }
    }

    /// Stops waiting on fetches a level or handler call left behind, dropping any reply already in.
    func forget(_ ids: Set<Int>) {
        locked {
            expected.subtract(ids)
            replies.removeAll { ids.contains($0.reply.id) }
        }
    }

    /// Every reply in, waiting for one until `deadline` (`ScriptTimers.now`'s clock), or for as long as it takes
    /// when there is none; empty once the deadline passes, or when the input has closed.
    func takeReplies(waitingUntil deadline: TimeInterval?) -> [Reply] {
        condition.lock()
        defer { condition.unlock() }
        while replies.isEmpty, !isInputClosed {
            guard let deadline else {
                condition.wait()
                continue
            }
            let remaining = deadline - ScriptTimers.now
            guard remaining > 0 else {
                break
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        let taken = replies
        replies.removeAll()
        return taken
    }

    /// The reader thread's body: queues each message until the input ends. A frame that can't be read ends it too,
    /// since nothing after it can be trusted.
    func read(from reader: ScriptInputReader) {
        let decoder = JSONDecoder()
        while case .frame(let frame) = reader.next(), let message = try? decoder.decode(ScriptRunnerMessage.self, from: frame) {
            var body = Data()
            if case .fetched(let reply) = message, case .response = reply.outcome {
                guard case .frame(let bytes) = reader.next() else {
                    break
                }
                body = bytes
            }
            condition.lock()
            switch message {
            case .item(let item):
                items.append(item)
            case .sendingClosed:
                isSendingOpen = false
            case .endOfItems:
                isEndOfItems = true
            case .fetched(let reply):
                if expected.remove(reply.id) != nil {
                    replies.append(Reply(reply: reply, body: body))
                }
            }
            condition.broadcast()
            condition.unlock()
        }
        condition.lock()
        isInputClosed = true
        condition.broadcast()
        condition.unlock()
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }
}
