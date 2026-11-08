import Foundation

/// What the app writes to the helper after its input and bodies, one frame each (`ScriptFraming`), in every phase.
/// Standard input closes only once the helper has exited: a phase never ends by its closing, since replies to the
/// requests its scripts sent arrive on it too, and a stream's item in hand may still be waiting on one.
public enum ScriptRunnerMessage: Hashable, Sendable, Codable {
    /// A stream phase's next item for the handlers. The app writes one only once the helper has finished the one
    /// before it (`ScriptRunnerEvent.callFinished`), so what waits stays on the app's side, where it is bounded and
    /// counted.
    case item(ScriptStreamItem)
    /// The connection or call no longer takes what `rq.send` sends.
    case sendingClosed
    /// A stream phase gets no more items: it ends once the item in hand has been handled.
    case endOfItems
    /// What a request a script sent got back (`ScriptRunnerEvent.fetch`). A `.response` reply's body follows as the
    /// next frame, raw.
    case fetched(ScriptFetchReply)
}
