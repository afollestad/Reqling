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

/// What a stream phase's reader thread hands the main thread: the items, in order, and whether `rq.send` can still
/// reply. Only this crosses threads; JavaScriptCore and `EventWriter` stay on the main thread.
final class ScriptStreamInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [ScriptStreamItem] = []
    private var isClosed = false
    private var isSendingOpen: Bool

    init(canSend: Bool) {
        isSendingOpen = canSend
    }

    var canSend: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isSendingOpen
    }

    /// The next item, waiting for one; `nil` once the input has ended and every item was taken.
    func next() -> ScriptStreamItem? {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty, !isClosed {
            condition.wait()
        }
        return items.isEmpty ? nil : items.removeFirst()
    }

    /// The reader thread's body: queues each frame's item until the input ends. A frame that can't be read ends it
    /// too, since nothing after it can be trusted.
    func read(from reader: ScriptInputReader) {
        let decoder = JSONDecoder()
        while case .frame(let frame) = reader.next(), let input = try? decoder.decode(ScriptStreamInput.self, from: frame) {
            condition.lock()
            switch input {
            case .item(let item):
                items.append(item)
            case .sendingClosed:
                isSendingOpen = false
            }
            condition.signal()
            condition.unlock()
        }
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }
}
